import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:velock_sync/features/connection/remote_object_store_factory.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_provisioner.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_scope_guard.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_local_folder_guard.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_access_authorizer.dart';
import 'package:velock_sync/features/cloud_backup/ui/backup_widgets.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_service.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/features/plain_sync/state/plain_remote_folders.dart';
import 'package:velock_sync/features/plain_sync/ui/plain_remote_folder_picker.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/features/sync_profiles/ui/sync_profile_providers.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_profiles/model/sync_profile_summary.dart';
import 'package:velock_sync/sync_profiles/settings/sync_global_settings.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart' show AppBackButton;
import 'plain_option_row.dart';

/// Three-step setup for one plain sync location:
/// 1. local folder, 2. remote folder, 3. direction and conflict handling.
class AddPlainLocation extends HookConsumerWidget {
  const AddPlainLocation({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = useState(0);
    final busy = useState(false);
    final grant = useState<FolderAccessGrant?>(null);
    final localName = useState<String?>(null);
    final connection = useState<ConnectionModel?>(null);
    final segments = useState<List<String>?>(null);
    final name = useState('');
    final direction = useState(MirrorDirection.bidirectional);
    final conflictPolicy = useState(MirrorConflictPolicy.keepBoth);
    final error = useState<String?>(null);

    final connections = ref.watch(connectionsProvider);
    final allConnections =
        connections.asData?.value ?? const <ConnectionModel>[];
    final supportedConnections = allConnections
        .where(
          (item) =>
              RemoteObjectStoreFactory.supportsPlainFolders(item.protocol),
        )
        .toList(growable: false);
    // Cloud drives without real folder paths cannot hold a plain mirror; they
    // are named on the page so a connection the user knows about does not
    // just go missing.
    final unsupportedConnections = allConnections
        .where(
          (item) =>
              !RemoteObjectStoreFactory.supportsPlainFolders(item.protocol),
        )
        .toList(growable: false);

    /// Lets the wizard finish without leaving it: opens the connection types
    /// file sync can use, and re-reads the connections when the user comes
    /// back. `returnTo=back` brings the user here instead of the connections
    /// tab once the new connection is saved.
    Future<void> addConnection() async {
      await context.pushNamed(
        AppRoutes.protocols.name,
        queryParameters: const {'returnTo': 'back', 'for': 'plain'},
      );
      if (!context.mounted) return;
      ref.invalidate(connectionsProvider);
      ref.invalidate(connectionRepositoryProvider);
    }

    Future<void> pickLocalFolder() async {
      if (busy.value) return;
      busy.value = true;
      error.value = null;
      try {
        final provisioner = PlainFolderProvisioner(
          authorizer: ref.read(folderAccessAuthorizerProvider),
          profiles: ref.read(plainFolderProfilesProvider),
          backups: ref.read(syncProfileRepositoryProvider),
        );
        final picked = await provisioner.pickLocalFolder();
        if (picked == null || !context.mounted) return;
        // Refuse a folder another location owns right away, not at the last
        // step. The earlier pick (if any) is kept so the user can go on.
        await provisioner.assertLocalFolderUnused(picked);
        final label = await provisioner.resolveLocalDisplayName(picked);
        if (!context.mounted) return;
        grant.value = picked;
        localName.value = label;
        if (name.value.trim().isEmpty) name.value = label;
      } on PlainLocalFolderInUseException catch (failure, stackTrace) {
        loge('Local folder already in use: $failure', stackTrace: stackTrace);
        if (!context.mounted) return;
        error.value = plainLocalFolderInUseMessage(context, failure);
      } on Object catch (failure, stackTrace) {
        loge('Local folder pick failed: $failure', stackTrace: stackTrace);
        error.value = syncText(
          context,
          '无法读取这个文件夹，请重新选择。',
          'Could not read that folder. Please pick again.',
        );
      } finally {
        busy.value = false;
      }
    }

    Future<void> pickRemoteFolder(ConnectionModel value) async {
      if (busy.value) return;
      if (!RemoteObjectStoreFactory.supportsPlainFolders(value.protocol)) {
        return;
      }
      busy.value = true;
      error.value = null;
      try {
        final folders = ref.read(plainRemoteFoldersProvider);
        final result = await pickPlainRemoteFolder(context, ref, value);
        if (result == null || !context.mounted) return;
        // The connection may have been edited inside the picker.
        final chosen = result.connection;
        final picked = result.segments;
        if (picked.isEmpty) {
          error.value = syncText(
            context,
            '请进入一个真实存在的文件夹再选择；连接根位置可能只是只读入口。',
            'Open a folder that really exists and select it. The connection root may be a read-only entry point.',
          );
          return;
        }
        // Refuse a backup folder right away instead of at the last step.
        await assertPlainFolderIsNotBackup(
          backups: ref.read(syncProfileRepositoryProvider),
          connectionId: chosen.id,
          segments: picked,
          childFolderNames: () async => [
            for (final folder in await folders.list(chosen, picked))
              folder.name,
          ],
        );
        if (!context.mounted) return;
        connection.value = chosen;
        segments.value = picked;
      } on BackupFolderOverlapException catch (failure) {
        if (!context.mounted) return;
        error.value = backupOverlapMessage(context, failure);
      } on Object catch (failure, stackTrace) {
        loge('Remote folder pick failed: $failure', stackTrace: stackTrace);
        error.value = syncText(
          context,
          '无法读取远端文件夹，请检查连接和网络。',
          'Could not read the remote folders. Check the connection and network.',
        );
      } finally {
        busy.value = false;
      }
    }

    /// Leaves the wizard whether or not it was pushed onto a stack: launched
    /// from the tab it pops, opened as the first route it returns to the tab.
    void leaveWizard() {
      if (context.canPop()) {
        context.pop(true);
        return;
      }
      context.go(AppRoutes.files.path);
    }

    /// One step back inside the wizard; from the first step it leaves.
    void goBack() {
      error.value = null;
      if (step.value > 0) {
        step.value = step.value - 1;
        return;
      }
      leaveWizard();
    }

    Future<void> create() async {
      final pickedGrant = grant.value;
      final pickedConnection = connection.value;
      final pickedSegments = segments.value;
      if (pickedGrant == null ||
          pickedConnection == null ||
          pickedSegments == null ||
          busy.value) {
        return;
      }
      busy.value = true;
      error.value = null;
      var created = false;
      try {
        final localData = ref.read(localDataManagerProvider);
        final deviceId = await resolvePlainSyncDeviceId(
          read: () => localData.getStringAsync(AppKeys.deviceId),
          write: (value) => localData.setStringAsync(AppKeys.deviceId, value),
          create: () => const Uuid().v4(),
        );
        // Safety checks first: a folder that belongs to a Velock backup, or that
        // contains/sits inside another sync location, must be refused BEFORE the
        // writability probe touches it (the probe writes and deletes a marker
        // file inside the chosen folder).
        await assertPlainScopeAvoidsBackups(
          backups: ref.read(syncProfileRepositoryProvider),
          connectionId: pickedConnection.id,
          segments: pickedSegments,
        );
        await assertPlainScopeAvoidsOtherLocations(
          profiles: ref.read(plainFolderProfilesProvider),
          connectionId: pickedConnection.id,
          segments: pickedSegments,
        );
        // Prove the chosen remote folder exists and accepts a write before the
        // location is created: a missing or read-only folder must be a setup
        // error, not a surprise on the first sync.
        busy.value = true;
        await ref.read(plainRemoteWritableCheckProvider)(
          connectionId: pickedConnection.id,
          remoteRootSegments: pickedSegments,
        );
        if (!context.mounted) return;
        // Resolve the localized fallbacks before awaiting anything: a stored
        // default must not be a language the device is not using, and no
        // BuildContext may be read across an async gap.
        final fallbackName = syncText(context, '同步位置', 'Sync location');
        final fallbackLocalName = syncText(context, '本机文件夹', 'Local folder');
        final settings = await LocalSyncGlobalSettingsStore(localData).read();
        await PlainFolderProvisioner(
          authorizer: ref.read(folderAccessAuthorizerProvider),
          profiles: ref.read(plainFolderProfilesProvider),
          backups: ref.read(syncProfileRepositoryProvider),
        ).create(
          grant: pickedGrant,
          displayName: name.value.trim().isEmpty
              ? (localName.value ?? fallbackName)
              : name.value.trim(),
          localDisplayName: localName.value ?? fallbackLocalName,
          connectionId: pickedConnection.id,
          deviceId: deviceId,
          remoteRootSegments: pickedSegments,
          direction: direction.value,
          conflictPolicy: conflictPolicy.value,
          backgroundPolicy: SyncProfileBackgroundPolicy(
            enabled: false,
            allowCellular: settings.defaultAllowCellular,
            requiresCharging: settings.defaultRequiresCharging,
            cellularMaxTransferBytes: settings.defaultCellularMaxTransferBytes,
          ),
        );
        created = true;
      } on PlainFolderSyncException catch (failure) {
        loge(
          'Plain location remote check failed: $failure',
          stackTrace: StackTrace.current,
        );
        // The service speaks to a location that already exists; here the user
        // is still one step away from choosing another folder.
        if (!context.mounted) return;
        error.value =
            failure.syncFailure.errorCode ==
                'plain_folder.remote_folder_unwritable'
            ? syncText(
                context,
                '这个远端文件夹不存在，或者这个账号不能写入。请返回上一步，选择另一个真实存在、可写入的文件夹。',
                'This remote folder is missing or this account cannot write to it. Go back one step and choose an existing, writable folder.',
              )
            : failure.syncFailure.suggestedAction;
      } on BackupFolderOverlapException catch (failure, stackTrace) {
        loge(
          'Plain location overlaps a backup: $failure',
          stackTrace: stackTrace,
        );
        if (!context.mounted) return;
        error.value = backupOverlapMessage(context, failure);
      } on PlainLocationOverlapException catch (failure, stackTrace) {
        loge(
          'Plain location overlaps another: $failure',
          stackTrace: stackTrace,
        );
        if (!context.mounted) return;
        error.value = syncText(
          context,
          '这个远端文件夹和另一个同步位置的远端文件夹互相包含：${failure.existingDisplayName}。两个同步位置覆盖同一批文件会互相覆盖，请换一个文件夹。',
          'This remote folder contains, or sits inside, the remote folder of another sync location: ${failure.existingDisplayName}. Two locations over the same files would overwrite each other, so pick a different folder.',
        );
      } on PlainLocalFolderInUseException catch (failure, stackTrace) {
        // Another location took this local folder while the wizard was open.
        loge(
          'Plain location local folder in use: $failure',
          stackTrace: stackTrace,
        );
        if (!context.mounted) return;
        error.value = plainLocalFolderInUseMessage(context, failure);
      } on FolderRootUnavailableException catch (failure, stackTrace) {
        loge(
          'Plain location local folder lost: $failure',
          stackTrace: stackTrace,
        );
        if (!context.mounted) return;
        error.value = syncText(
          context,
          '刚才选择的本机文件夹已经不可访问，请返回上一步重新选择。',
          'The local folder is no longer accessible. Go back one step and choose it again.',
        );
      } on Object catch (failure, stackTrace) {
        loge('Plain location create failed: $failure', stackTrace: stackTrace);
        if (!context.mounted) return;
        error.value = syncText(
          context,
          '创建同步位置失败，请重试。',
          'Could not create the sync location. Please try again.',
        );
      } finally {
        busy.value = false;
      }
      // Navigation is deliberately outside the try: once the profile is saved,
      // a routing hiccup must never be shown as "creation failed".
      if (!created || !context.mounted) return;
      ref.read(profilesRevisionProvider.notifier).bump();
      ref.invalidate(plainLocationViewsProvider);
      leaveWizard();
    }

    final nameController = useTextEditingController(text: name.value);
    final titles = [
      syncText(context, '选择本机文件夹', 'Choose the local folder'),
      syncText(context, '选择远端文件夹', 'Choose the remote folder'),
      syncText(context, '同步方式', 'How to sync'),
    ];
    return AdaptiveScaffold(
      title: syncText(context, '添加同步位置', 'Add a sync location'),
      leading: AppBackButton(
        onPressed: goBack,
        semanticLabel: step.value > 0
            ? syncText(context, '上一步', 'Previous step')
            : syncText(context, '返回文件同步', 'Back to file sync'),
      ),
      // The step indicator is pinned in the body, above the scrolling form, so
      // it stays visible while the user scrolls. It is deliberately NOT in the
      // navigation bar's trailing slot: that slot shrinks frame by frame during
      // a route transition and overflows whatever is in it (debug stripes).
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.sm,
              AppSpacing.page,
              AppSpacing.xs,
            ),
            child: Text(
              syncText(
                context,
                '第 ${step.value + 1} 步，共 3 步',
                'Step ${step.value + 1} of 3',
              ),
              key: const Key('plain-wizard-step'),
              style: AppType.footnote.copyWith(
                color: context.appSecondaryLabel,
              ),
            ),
          ),
          // What this step asks for, in one line, always visible.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.sm,
            ),
            child: Text(
              titles[step.value],
              key: const Key('plain-wizard-step-title'),
              style: AppType.cardTitle,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: AppSpacing.xl),
              children: [
                if (step.value == 0)
                  ..._localStep(
                    context,
                    grant.value,
                    localName.value,
                    busy.value,
                    pickLocalFolder,
                  )
                else if (step.value == 1)
                  ..._remoteStep(
                    context,
                    supportedConnections,
                    unsupportedConnections,
                    connections.isLoading,
                    connection.value,
                    segments.value,
                    busy.value,
                    pickRemoteFolder,
                    addConnection,
                  )
                else
                  ..._modeStep(
                    context,
                    nameController,
                    name,
                    direction,
                    conflictPolicy,
                    localName.value,
                    connection.value,
                    segments.value,
                  ),
                if (error.value != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.xs,
                      AppSpacing.page,
                      0,
                    ),
                    child: Text(
                      error.value!,
                      key: const Key('plain-wizard-error'),
                      style: AppType.footnote.copyWith(
                        color: AppTone.danger.color(context),
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.md),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.page,
                  ),
                  child: Row(
                    children: [
                      if (step.value > 0)
                        Expanded(
                          child: BackupActionButton(
                            label: syncText(context, '上一步', 'Back'),
                            secondary: true,
                            onPressed: busy.value ? null : goBack,
                          ),
                        ),
                      if (step.value > 0) const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: switch (step.value) {
                          0 => BackupActionButton(
                            key: const Key('plain-wizard-next-1'),
                            label: syncText(context, '下一步', 'Next'),
                            onPressed: grant.value == null || busy.value
                                ? null
                                : () {
                                    error.value = null;
                                    step.value = 1;
                                  },
                          ),
                          1 => BackupActionButton(
                            key: const Key('plain-wizard-next-2'),
                            label: syncText(context, '下一步', 'Next'),
                            onPressed: segments.value == null || busy.value
                                ? null
                                : () {
                                    // The folder name is only known after step
                                    // 1, so the default name is seeded when
                                    // step 3 opens.
                                    if (nameController.text.trim().isEmpty) {
                                      nameController.text = name.value;
                                    }
                                    error.value = null;
                                    step.value = 2;
                                  },
                          ),
                          _ => BackupActionButton(
                            key: const Key('plain-wizard-create'),
                            label: syncText(context, '创建', 'Create'),
                            busy: busy.value,
                            onPressed: busy.value ? null : create,
                          ),
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _localStep(
    BuildContext context,
    FolderAccessGrant? grant,
    String? localName,
    bool busy,
    Future<void> Function() pick,
  ) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.sm,
      ),
      child: Text(
        syncText(
          context,
          '这个文件夹里的文件名和目录结构会原样出现在远端文件夹里。系统会询问一次访问权限。',
          'The file names and folders inside appear exactly like this on the remote side. The system asks once for access.',
        ),
        style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
      ),
    ),
    AdaptiveListSection(
      children: [
        AdaptiveListTile(
          widgetKey: const Key('plain-pick-local'),
          leading: const Icon(CupertinoIcons.folder),
          title: Text(
            localName ?? syncText(context, '选择本机文件夹', 'Choose a local folder'),
          ),
          subtitle: Text(
            localName == null
                ? syncText(context, '还没有选择', 'Nothing selected yet')
                : syncText(context, '已选择', 'Selected'),
          ),
          showChevron: true,
          enabled: !busy,
          onTap: pick,
        ),
      ],
    ),
  ];

  List<Widget> _remoteStep(
    BuildContext context,
    List<ConnectionModel> connections,
    List<ConnectionModel> unsupported,
    bool loading,
    ConnectionModel? selected,
    List<String>? segments,
    bool busy,
    Future<void> Function(ConnectionModel) pick,
    Future<void> Function() onAddConnection,
  ) {
    if (loading && connections.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
          child: AdaptiveLoadingState(
            label: syncText(context, '正在读取连接', 'Loading connections'),
          ),
        ),
      ];
    }
    if (connections.isEmpty) {
      return [
        BackupCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                syncText(context, '还没有可用的远端连接', 'No remote connection yet'),
                style: AppType.rowTitleStrong,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                syncText(
                  context,
                  '文件夹同步可以用 WebDAV（NAS）、OneDrive、Google Drive、百度网盘或阿里云盘。先添加一个连接，选好文件夹后就能开始同步。',
                  'File sync works with WebDAV (a NAS), OneDrive, Google Drive, Baidu Netdisk or Aliyun Drive. Add one connection, pick the folder, and syncing can start.',
                ),
                style: TextStyle(color: context.appSecondaryLabel),
              ),
              const SizedBox(height: AppSpacing.md),
              // A dead end otherwise: the user had to abandon the wizard, find
              // the connections page by hand and come back.
              BackupActionButton(
                key: const Key('plain-add-connection'),
                label: syncText(context, '添加云端连接', 'Add a connection'),
                onPressed: () => onAddConnection(),
              ),
            ],
          ),
        ),
        ?_unsupportedNote(context, unsupported),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          0,
          AppSpacing.page,
          AppSpacing.sm,
        ),
        child: Text(
          syncText(
            context,
            '选择一个连接，然后进入这个连接里的一个文件夹。远端文件夹里已有的文件会被保留，第一次同步不会删除它们。',
            'Pick a connection, then open a folder inside it. Existing files in that remote folder are kept: the first sync never deletes them.',
          ),
          style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
        ),
      ),
      AdaptiveListSection(
        children: [
          for (final item in connections)
            AdaptiveListTile(
              widgetKey: Key('plain-remote-${item.id}'),
              leading: Icon(
                item.protocol is WebDavProtocolModel
                    ? CupertinoIcons.cloud
                    : CupertinoIcons.cloud_fill,
              ),
              title: Text(item.name),
              subtitle: Text(
                selected?.id == item.id && segments != null
                    ? '/${segments.join('/')}'
                    : syncText(context, '选择一个文件夹', 'Choose a folder'),
              ),
              showChevron: true,
              enabled: !busy,
              onTap: () => pick(item),
            ),
          // Saved connections are not the only choice: a new server can be
          // added without leaving the wizard (the empty state offers the same).
          AdaptiveListTile(
            widgetKey: const Key('plain-add-another-connection'),
            leading: const Icon(CupertinoIcons.add_circled),
            title: Text(syncText(context, '添加新的云端连接', 'Add a new connection')),
            subtitle: Text(
              syncText(
                context,
                'WebDAV、OneDrive、Google Drive、百度网盘或阿里云盘',
                'WebDAV, OneDrive, Google Drive, Baidu Netdisk or Aliyun Drive',
              ),
            ),
            showChevron: true,
            enabled: !busy,
            onTap: () => onAddConnection(),
          ),
        ],
      ),
      ?_unsupportedNote(context, unsupported),
    ];
  }

  /// Explains why saved cloud-drive connections are not offered here.
  Widget? _unsupportedNote(
    BuildContext context,
    List<ConnectionModel> unsupported,
  ) {
    if (unsupported.isEmpty) return null;
    final names = unsupported.map((item) => '「${item.name}」').join('、');
    final englishNames = unsupported.map((item) => '"${item.name}"').join(', ');
    return Padding(
      key: const Key('plain-unsupported-connections'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.sm,
        AppSpacing.page,
        0,
      ),
      child: Text(
        syncText(
          context,
          '已保存的连接 $names 不在这里：它只能访问 Sync 自己建的文件和隐藏的专用文件夹，用于格间备份。要同步 Google Drive 里的普通文件夹，请点“添加新的云端连接”，新建一个允许访问全部文件的 Google Drive 连接。',
          unsupported.length == 1
              ? 'Your saved connection $englishNames is not listed: it can only reach Sync’s own files and its hidden app folder, for Velock backups. To sync an ordinary Google Drive folder, choose “Add a new connection” and add a Google Drive connection with access to all files.'
              : 'Your saved connections $englishNames are not listed: they can only reach Sync’s own files and its hidden app folder, for Velock backups. To sync an ordinary Google Drive folder, choose “Add a new connection” and add a Google Drive connection with access to all files.',
        ),
        style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
      ),
    );
  }

  List<Widget> _modeStep(
    BuildContext context,
    TextEditingController nameController,
    ValueNotifier<String> name,
    ValueNotifier<MirrorDirection> direction,
    ValueNotifier<MirrorConflictPolicy> conflictPolicy,
    String? localName,
    ConnectionModel? connection,
    List<String>? segments,
  ) => [
    AdaptiveListSection(
      children: [
        AdaptiveListTile(
          leading: const Icon(CupertinoIcons.tag),
          title: Text(syncText(context, '名称', 'Name')),
          subtitle: TextField(
            key: const Key('plain-name-field'),
            controller: nameController,
            decoration: InputDecoration(
              isDense: true,
              hintText: syncText(context, '同步位置名称', 'Location name'),
            ),
            onChanged: (value) => name.value = value,
          ),
        ),
        AdaptiveListTile(
          leading: const Icon(CupertinoIcons.device_phone_portrait),
          title: Text(syncText(context, '本机', 'This device')),
          subtitle: Text(localName ?? '-'),
        ),
        AdaptiveListTile(
          leading: const Icon(CupertinoIcons.cloud),
          title: Text(syncText(context, '远端', 'Remote')),
          subtitle: Text(
            segments == null
                ? '-'
                : '${connection?.name ?? ''} · /${segments.join('/')}',
          ),
        ),
      ],
    ),
    AdaptiveListSection(
      header: syncText(context, '方向和删除行为', 'Direction and deletions'),
      children: [
        for (final value in MirrorDirection.values)
          PlainOptionRow(
            widgetKey: Key('plain-direction-${value.name}'),
            selected: value == direction.value,
            title: directionLabel(context, value),
            explanation: directionExplanation(context, value),
            onTap: () => direction.value = value,
          ),
      ],
    ),
    if (direction.value == MirrorDirection.bidirectional)
      AdaptiveListSection(
        header: syncText(context, '冲突处理', 'Conflicts'),
        children: [
          for (final value in MirrorConflictPolicy.values)
            PlainOptionRow(
              widgetKey: Key('plain-conflict-${value.name}'),
              selected: value == conflictPolicy.value,
              title: conflictPolicyLabel(context, value),
              explanation: conflictPolicyExplanation(context, value),
              onTap: () => conflictPolicy.value = value,
            ),
        ],
      ),
    Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.xs,
        AppSpacing.page,
        0,
      ),
      child: Text(
        firstSyncNote(context, direction.value),
        key: const Key('plain-first-sync-note'),
        style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
      ),
    ),
  ];
}

/// What the first sync of a new location does, for the chosen direction.
///
/// QA 2026-09-29: the note always described the two-way merge, even when
/// "upload only" or "download only" was selected.
String firstSyncNote(BuildContext context, MirrorDirection direction) {
  final merge = switch (direction) {
    MirrorDirection.bidirectional => syncText(
      context,
      '第一次同步会合并两边：只在本机的文件上传，只在远端的文件下载，两边都有但内容不同的文件按冲突设置处理。',
      'The first sync merges both sides: files only here are uploaded, files only there are downloaded, and files that differ follow the conflict setting.',
    ),
    MirrorDirection.uploadOnly => syncText(
      context,
      '第一次同步只上传：本机的文件上传到远端，两边内容不同时用本机版本覆盖远端；只在远端的文件保持原样，不会下载。',
      'The first sync only uploads: files here are uploaded, and where both sides differ the remote copy is replaced with this device\'s. Files only on the remote stay there and are not downloaded.',
    ),
    MirrorDirection.downloadOnly => syncText(
      context,
      '第一次同步只下载：远端的文件下载到本机，两边内容不同时用远端版本覆盖本机；只在本机的文件保持原样，不会上传。',
      'The first sync only downloads: remote files are downloaded, and where both sides differ this device\'s copy is replaced with the remote one. Files only on this device stay here and are not uploaded.',
    ),
  };
  final plaintext = syncText(
    context,
    '远端是明文，请确认这个账号只有你自己可访问。',
    'The remote folder is not encrypted, so make sure only you can access that account.',
  );
  return syncText(context, '$merge$plaintext', '$merge $plaintext');
}

/// Why a remote folder that holds (or contains) a Velock backup is refused,
/// naming both folders so the user can see which one to pick instead.
String backupOverlapMessage(
  BuildContext context,
  BackupFolderOverlapException failure,
) {
  String path(List<String> segments) => '/${segments.join('/')}';
  final chosen = path(failure.chosenSegments);
  final backupSegments = failure.backupSegments;
  // Translated on its own, so every language gets it inside the messages below.
  final why = syncText(
    context,
    '文件同步会把选中文件夹里的所有文件当成普通文件来上传、下载甚至删除，格间的加密备份会被弄坏，所以不能选它。',
    'File sync uploads, downloads and even deletes every file in the chosen folder as an ordinary file, which would damage the encrypted Velock backup, so it cannot be used.',
  );
  if (failure.backupName.isEmpty || backupSegments == null) {
    return syncText(
      context,
      '你选的文件夹 $chosen 里有格间的加密备份（或它本身就在一份备份里）。$why请换一个文件夹，或者新建一个专门用于同步的文件夹。',
      'The folder you chose, $chosen, holds a Velock encrypted backup or sits inside one. $why Choose another folder, or create a new one just for syncing.',
    );
  }
  final backup = path(backupSegments);
  final name = failure.backupName;
  if (failure.containsBackup) {
    final child = backupSegments[failure.chosenSegments.length];
    return syncText(
      context,
      '你选的文件夹 $chosen 里面，有格间备份「$name」用的文件夹 $backup。$why请选一个里面不含「$child」的文件夹，或者在这里新建一个专门用于同步的文件夹。',
      'The folder you chose, $chosen, contains $backup, the folder of the Velock backup “$name”. $why Choose a folder that does not contain “$child”, or create a new folder here just for syncing.',
    );
  }
  if (failure.insideBackup) {
    return syncText(
      context,
      '你选的文件夹 $chosen 在格间备份「$name」用的文件夹 $backup 里面。$why请选备份文件夹以外的位置。',
      'The folder you chose, $chosen, is inside $backup, the folder of the Velock backup “$name”. $why Choose a place outside the backup folder.',
    );
  }
  return syncText(
    context,
    '你选的文件夹 $chosen 就是格间备份「$name」用的文件夹。$why请换一个文件夹，或者新建一个专门用于同步的文件夹。',
    'The folder you chose, $chosen, is the folder of the Velock backup “$name”. $why Choose another folder, or create a new one just for syncing.',
  );
}
