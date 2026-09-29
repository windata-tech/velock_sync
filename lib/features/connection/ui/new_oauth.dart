import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/app_repository.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/main.dart' show oauthCallbackLinkReceiver;
import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_browser_authorization.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_folder_picker.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

/// Creates a Google Drive or OneDrive connection through system-browser PKCE.
/// It deliberately never renders, stores, or logs an access/refresh token.
class NewOAuthConnection extends HookConsumerWidget {
  const NewOAuthConnection({
    super.key,
    required this.providerType,
    this.replacementConnectionId,
    this.returnTo,
  });

  final RemoteProviderType providerType;
  final String? replacementConnectionId;
  final String? returnTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formKey = useMemoized(GlobalKey<FormState>.new);
    // Release builds only use the client ID built into the app; the developer
    // form and any Client ID saved through it are debug-only.
    final allowsDeveloperClientId = ref
        .watch(remoteProviderAvailabilityProvider)
        .allowsDeveloperClientId;
    final localDataManager = ref.read(localDataManagerProvider);
    final clientIdController = useTextEditingController();
    final savedClientId = useFuture(
      useMemoized(
        () => localDataManager.getStringAsync(_oauthClientIdKey(providerType)),
        [providerType],
      ),
    );
    // A manually entered public client ID is applied only after Save. Switching
    // screens on every keystroke would dismiss the developer form mid-entry.
    final manualClientId = useState<String?>(null);
    useEffect(() {
      if (savedClientId.hasData && clientIdController.text.isEmpty) {
        clientIdController.text = savedClientId.data ?? '';
      }
      return null;
    }, [savedClientId.data]);
    final rootController = useTextEditingController(
      text: providerType == RemoteProviderType.googleDrive
          ? 'appDataFolder'
          : 'root',
    );
    final accountController = useTextEditingController();
    final isLoading = useState(false);
    OAuthAuthorizationConfig? config;
    Object? registrationError;
    try {
      config = OAuthPublicClientConfiguration.forProvider(providerType);
    } on Object catch (error) {
      final clientId = allowsDeveloperClientId
          ? (manualClientId.value ?? savedClientId.data ?? '').trim()
          : '';
      if (clientId.isEmpty) {
        registrationError = error;
      } else {
        try {
          config = OAuthPublicClientConfiguration.fromClientId(
            providerType: providerType,
            clientId: clientId,
          );
        } on Object catch (runtimeError) {
          registrationError = runtimeError;
        }
      }
    }

    Future<void> saveClientId() async {
      final clientId = clientIdController.text.trim();
      if (clientId.isEmpty) {
        showPlatformMessage(
          context,
          syncText(context, '请输入公开 Client ID。', 'Enter the public Client ID.'),
        );
        return;
      }
      try {
        OAuthPublicClientConfiguration.fromClientId(
          providerType: providerType,
          clientId: clientId,
        );
        await localDataManager.setStringAsync(
          _oauthClientIdKey(providerType),
          clientId,
        );
        if (context.mounted) manualClientId.value = clientId;
      } on Object {
        if (context.mounted) {
          showPlatformMessage(
            context,
            syncText(
              context,
              '无法保存授权配置，请检查后重试。',
              'Could not save the authorization settings. Check them and retry.',
            ),
          );
        }
      }
    }

    Future<void> authorizeAndSave() async {
      if (config == null || formKey.currentState?.validate() != true) return;
      final authorizationConfig = config;
      isLoading.value = true;
      String? credentialRef;
      var saved = false;
      try {
        final authorization = OAuthBrowserAuthorization(
          service: OAuthAuthorizationService(
            session: OAuthAuthorizationSession(
              stateStore: SecureOAuthAuthorizationStateStore(),
            ),
            tokenClient: OAuthTokenClient(),
            credentialStore: ref.read(credentialStoreProvider),
          ),
        );
        credentialRef = await authorization.authorize(
          config: authorizationConfig,
          callbackReceiver: oauthCallbackLinkReceiver,
        );
        if (!context.mounted) return;
        final selectedRootId = await _selectRemoteFolder(
          context: context,
          providerType: providerType,
          credentialStore: ref.read(credentialStoreProvider),
          target: OAuthRemoteTargetConfig(
            providerType: providerType,
            clientId: authorizationConfig.clientId,
            credentialRef: credentialRef,
            rootId: rootController.text.trim(),
          ),
        );
        if (selectedRootId == null) return;
        rootController.text = selectedRootId;
        final protocol = ProtocolModel.oauth(
          providerType: providerType,
          clientId: authorizationConfig.clientId,
          credentialRef: credentialRef,
          rootId: selectedRootId,
          accountLabel: accountController.text.trim().isEmpty
              ? null
              : accountController.text.trim(),
        );
        // Plain probe: avoids the Riverpod 3 UnmountedRefException race that
        // an autoDispose provider's `.future` can hit when the provider is
        // disposed while the await is pending.
        final connected = await ref.read(protocolConnectionProbeProvider)(
          credentials: ref.read(credentialStoreProvider),
          protocol: protocol,
        );
        if (!connected) {
          throw StateError('Provider connection check failed.');
        }
        if (replacementConnectionId == null) {
          await ref
              .read(connectionCreationProvider.notifier)
              .setProtocolAndFinalize(protocolModel: protocol);
        } else {
          await ref
              .read(connectionsProvider.notifier)
              .replaceOAuthConnection(
                connectionId: replacementConnectionId!,
                protocol: protocol as OAuthProtocolModel,
              );
        }
        saved = true;
        if (context.mounted) context.go(returnTo ?? AppRoutes.connections.path);
      } on Object catch (error, stackTrace) {
        loge(
          'OAuth authorization or connection check failed: ${error.runtimeType}',
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          showPlatformMessage(
            context,
            syncText(
              context,
              '未能完成登录或连接，请重试。',
              'Sign-in or connection did not finish. Please retry.',
            ),
          );
        }
      } finally {
        if (!saved && credentialRef != null) {
          await ref
              .read(connectionRepositoryProvider)
              .deleteCredential(credentialRef);
        }
        isLoading.value = false;
      }
    }

    final provider = _providerLabel(providerType);
    return AdaptivePageScaffold(
      appBar: WDAppBar(
        title: Text(
          syncText(
            context,
            '${replacementConnectionId == null ? '连接' : '重新登录'} $provider',
            '${replacementConnectionId == null ? 'Connect' : 'Sign in again to'} $provider',
          ),
        ),
        trailingActions: [
          AdaptiveTextButton(
            padding: EdgeInsets.zero,
            onPressed: () => context.pushNamed(
              AppRoutes.connectionHelp.name,
              queryParameters: {'provider': providerType.name},
            ),
            child: Text(syncText(context, '帮助', 'Help')),
          ),
        ],
      ),
      body: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xl),
          child: config == null
              ? _MissingOAuthRegistration(
                  providerType: providerType,
                  error: registrationError,
                  clientIdController: clientIdController,
                  showDeveloperSettings: allowsDeveloperClientId,
                  onSave: saveClientId,
                  onChooseAnother: () => context.goNamed(
                    AppRoutes.protocols.name,
                    queryParameters: {'returnTo': ?returnTo},
                  ),
                )
              : Form(
                  key: formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.page),
                    children: [
                      const SizedBox(height: 12),
                      const Icon(CupertinoIcons.cloud, size: 42),
                      const SizedBox(height: 20),
                      Text(
                        syncText(
                          context,
                          '连接你的 $provider',
                          'Connect your $provider',
                        ),
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        syncText(
                          context,
                          '在浏览器中登录你的云端账号，然后选择保存位置。无需把云盘密码交给 Sync。',
                          'Sign in to your cloud account in the browser, then choose where to save. You do not give your cloud password to Sync.',
                        ),
                        style: TextStyle(
                          color: context.appSecondaryLabel,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      AdaptiveElevatedButton(
                        key: const Key('oauth-sign-in'),
                        onPressed: isLoading.value ? null : authorizeAndSave,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            syncText(
                              context,
                              isLoading.value ? '正在连接…' : '登录并选择保存位置',
                              isLoading.value
                                  ? 'Connecting…'
                                  : 'Sign in and choose a location',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ExpansionTile(
                        key: const Key('oauth-advanced-location'),
                        title: Text(
                          syncText(
                            context,
                            '更多设置（可选）',
                            'More settings (optional)',
                          ),
                        ),
                        childrenPadding: const EdgeInsets.all(12),
                        children: [
                          TextFormField(
                            controller: accountController,
                            decoration: InputDecoration(
                              labelText: syncText(
                                context,
                                '账号备注',
                                'Account nickname',
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const Key('oauth-root-id'),
                            controller: rootController,
                            decoration: InputDecoration(
                              labelText: syncText(
                                context,
                                '起始文件夹标识（高级）',
                                'Starting folder ID (advanced)',
                              ),
                              helperText: syncText(
                                context,
                                '一般无需修改，登录后可以直接选择文件夹。',
                                'Usually leave this unchanged. Pick a folder after signing in.',
                              ),
                              helperMaxLines: 3,
                            ),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                ? syncText(
                                    context,
                                    '请填写文件夹标识或保留默认值。',
                                    'Enter a folder ID or keep the default.',
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

Future<String?> _selectRemoteFolder({
  required BuildContext context,
  required RemoteProviderType providerType,
  required CredentialStore credentialStore,
  required OAuthRemoteTargetConfig target,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _OAuthFolderPickerSheet(
    providerType: providerType,
    picker: OAuthRemoteFolderPicker(credentialStore: credentialStore),
    target: target,
  ),
);

class _OAuthFolderPickerSheet extends StatefulWidget {
  const _OAuthFolderPickerSheet({
    required this.providerType,
    required this.picker,
    required this.target,
  });

  final RemoteProviderType providerType;
  final OAuthRemoteFolderPicker picker;
  final OAuthRemoteTargetConfig target;

  @override
  State<_OAuthFolderPickerSheet> createState() =>
      _OAuthFolderPickerSheetState();
}

class _OAuthFolderPickerSheetState extends State<_OAuthFolderPickerSheet> {
  String? _parentId;
  final List<String?> _history = [];
  late Future<List<OAuthRemoteFolder>> _folders;

  @override
  void initState() {
    super.initState();
    _parentId = widget.providerType == RemoteProviderType.googleDrive
        ? null
        : widget.target.rootId == 'root'
        ? null
        : widget.target.rootId;
    _loadFolders();
  }

  void _loadFolders() {
    _folders = widget.picker.listAllFolders(
      target: widget.target,
      parentId: _parentId,
    );
  }

  void _goTo(String? parentId) {
    setState(() {
      _parentId = parentId;
      _loadFolders();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedId = _parentId ?? 'root';
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          children: [
            ListTile(
              title: Text(syncText(context, '选择云端位置', 'Choose cloud storage')),
              subtitle: Text(
                syncText(
                  context,
                  _parentId == null ? '所有文件夹' : '当前文件夹',
                  _parentId == null ? 'All folders' : 'Current folder',
                ),
              ),
              leading: _history.isEmpty
                  ? const Icon(Icons.folder_outlined)
                  : AppBackButton(
                      semanticLabel: syncText(
                        context,
                        '返回上一级文件夹',
                        'Parent folder',
                      ),
                      onPressed: () => _goTo(_history.removeLast()),
                    ),
              trailing: TextButton(
                onPressed: () => Navigator.pop(context, selectedId),
                child: Text(syncText(context, '保存在这里', 'Save here')),
              ),
            ),
            if (widget.providerType == RemoteProviderType.googleDrive &&
                _parentId == null)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(
                  syncText(context, 'Sync 专用文件夹', 'Sync’s private folder'),
                ),
                subtitle: Text(
                  syncText(
                    context,
                    '自动管理，不会与其他文件混在一起',
                    'Managed automatically, separate from your other files',
                  ),
                ),
                onTap: () => Navigator.pop(context, 'appDataFolder'),
              ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<OAuthRemoteFolder>>(
                future: _folders,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '无法读取文件夹：${AppFormat.errorSummary(snapshot.error?.toString())}',
                        ),
                      ),
                    );
                  }
                  final items = snapshot.requireData;
                  if (items.isEmpty) {
                    return Center(
                      child: Text(
                        syncText(
                          context,
                          '这里没有其他文件夹。',
                          'There are no other folders here.',
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final folder = items[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          _history.add(_parentId);
                          _goTo(folder.id);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingOAuthRegistration extends StatelessWidget {
  const _MissingOAuthRegistration({
    required this.providerType,
    required this.error,
    required this.clientIdController,
    required this.showDeveloperSettings,
    required this.onSave,
    required this.onChooseAnother,
  });

  final RemoteProviderType providerType;
  final Object? error;
  final TextEditingController clientIdController;
  final bool showDeveloperSettings;
  final Future<void> Function() onSave;
  final VoidCallback onChooseAnother;

  @override
  Widget build(BuildContext context) {
    final provider = _providerLabel(providerType);
    final clientIdKey = providerType == RemoteProviderType.googleDrive
        ? 'GOOGLE_OAUTH_CLIENT_ID'
        : 'ONEDRIVE_OAUTH_CLIENT_ID';
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.page),
      children: [
        const SizedBox(height: 12),
        const Icon(CupertinoIcons.exclamationmark_circle, size: 40),
        const SizedBox(height: 20),
        Text(
          syncText(
            context,
            '此版本暂未开通 $provider',
            '$provider is not set up in this build',
          ),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          syncText(
            context,
            '这是应用的连接配置尚未准备好，不是你的账号有问题。你可以先选择其他云端位置，或使用已开通此服务的版本。',
            'The app’s connection configuration is not ready; there is no problem with your account. Choose another location or use a build with this service configured.',
          ),
          style: TextStyle(color: context.appSecondaryLabel, height: 1.5),
        ),
        const SizedBox(height: 22),
        AdaptiveElevatedButton(
          key: const Key('oauth-choose-another'),
          onPressed: onChooseAnother,
          child: Text(
            syncText(context, '选择其他保存位置', 'Choose another location'),
            textAlign: TextAlign.center,
          ),
        ),
        if (showDeveloperSettings) ...[
          const SizedBox(height: 22),
          ExpansionTile(
            key: const Key('oauth-developer-settings'),
            title: Text(syncText(context, '开发者配置', 'Developer settings')),
            subtitle: Text(
              syncText(context, '普通用户无需配置', 'Not required for everyday use'),
            ),
            childrenPadding: const EdgeInsets.all(12),
            children: [
              Text(
                syncText(
                  context,
                  '自定义构建可填写公开 Client ID，或在构建时传入 $clientIdKey。不要填写 Client Secret。',
                  'For custom builds, enter a public Client ID or provide $clientIdKey at build time. Do not enter a Client Secret.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('oauth-client-id-field'),
                controller: clientIdController,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Client ID'),
              ),
              const SizedBox(height: 12),
              AdaptiveTextButton(
                key: const Key('oauth-save-client-id'),
                onPressed: onSave,
                child: Text(
                  syncText(context, '保存开发者配置', 'Save developer settings'),
                ),
              ),
              const Text('velocksync://oauth/callback', style: AppType.mono),
              AppDetailDisclosure(
                detail: '${error.runtimeType}\n${_errorCode(error)}',
              ),
            ],
          ),
        ],
      ],
    );
  }
}

String _providerLabel(RemoteProviderType providerType) =>
    switch (providerType) {
      RemoteProviderType.googleDrive => 'Google Drive',
      RemoteProviderType.oneDrive => 'OneDrive',
      RemoteProviderType.baiduNetdisk => '百度网盘',
      RemoteProviderType.aliyunDrive => '阿里云盘',
      RemoteProviderType.webDav => 'WebDAV',
    };

String _oauthClientIdKey(RemoteProviderType providerType) =>
    switch (providerType) {
      RemoteProviderType.googleDrive => AppKeys.googleOAuthClientId,
      RemoteProviderType.oneDrive => AppKeys.oneDriveOAuthClientId,
      _ => throw ArgumentError.value(providerType, 'providerType'),
    };

String _errorCode(Object? error) {
  final text = error.toString();
  if (text.contains('OAuthClientRegistrationMissing')) {
    return 'provider.oauth.client_id_missing';
  }
  return text;
}
