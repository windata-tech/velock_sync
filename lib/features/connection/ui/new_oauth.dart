import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/infrastructure/secure_storage/credential_store.dart';
import 'package:velock_sync/main.dart' show oauthCallbackLinkReceiver;
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_object_store.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_service.dart';
import 'package:velock_sync/providers/oauth/oauth_authorization_session.dart';
import 'package:velock_sync/providers/oauth/oauth_browser_authorization.dart';
import 'package:velock_sync/providers/oauth/oauth_client_registration.dart';
import 'package:velock_sync/providers/oauth/oauth_public_client_configuration.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_folder_picker.dart';
import 'package:velock_sync/providers/oauth/oauth_remote_target_factory.dart';
import 'package:velock_sync/providers/oauth/oauth_token_client.dart';
import 'package:velock_sync/providers/oauth/oauth_user_registration_provider.dart';
import 'package:velock_sync/providers/oauth/oauth_web_authentication_session.dart';
import 'package:velock_sync/providers/remote_provider_availability.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/app_format.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';
import 'package:velock_sync/l10n/sync_locale.dart';

/// Creates an OAuth cloud-drive connection through the system browser.
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
    // The user's own app registration (secure storage) wins over the one
    // built into this build; the repository itself ships none.
    final userRegistration = ref.watch(
      oauthUserRegistrationProvider(providerType),
    );
    final ownRegistration = userRegistration.value;
    final editingOwnKey = useState(false);
    final baiduAppFolder = baiduNetdiskAppFolderFor(
      ownRegistration?.appFolderName,
    );
    final rootController = useTextEditingController(
      text: switch (providerType) {
        RemoteProviderType.googleDrive => 'appDataFolder',
        RemoteProviderType.baiduNetdisk => baiduAppFolder,
        _ => 'root',
      },
    );
    useEffect(() {
      if (providerType == RemoteProviderType.baiduNetdisk) {
        rootController.text = baiduAppFolder;
      }
      return null;
    }, [baiduAppFolder]);
    final accountController = useTextEditingController();
    final isLoading = useState(false);
    OAuthAuthorizationConfig? config;
    if (ownRegistration != null) {
      try {
        config = OAuthPublicClientConfiguration.fromUserRegistration(
          providerType: providerType,
          registration: ownRegistration,
        );
      } on Object {
        config = null;
      }
    } else if (OAuthPublicClientConfiguration.hasBuiltInRegistration(
      providerType,
    )) {
      config = OAuthPublicClientConfiguration.forProvider(providerType);
    }

    Future<bool> saveOwnRegistration(
      OAuthClientRegistration registration,
    ) async {
      try {
        await ref
            .read(credentialStoreProvider)
            .writeOAuthClientRegistration(providerType, registration);
      } on Object catch (error, stackTrace) {
        loge(
          'Saving the OAuth app registration failed: ${error.runtimeType}',
          stackTrace: stackTrace,
        );
        return false;
      }
      ref.invalidate(oauthUserRegistrationProvider(providerType));
      if (context.mounted) editingOwnKey.value = false;
      return true;
    }

    Future<void> removeOwnRegistration() async {
      try {
        await ref
            .read(credentialStoreProvider)
            .deleteOAuthClientRegistration(providerType);
      } on Object catch (error, stackTrace) {
        loge(
          'Removing the OAuth app registration failed: ${error.runtimeType}',
          stackTrace: stackTrace,
        );
      }
      ref.invalidate(oauthUserRegistrationProvider(providerType));
      if (context.mounted) editingOwnKey.value = false;
    }

    // `go` would replace the whole stack and leave the protocol list with
    // nothing to go back to. New connections are only opened from that list,
    // so pop back to it; editors opened elsewhere swap in the list and keep
    // their opener below.
    void chooseAnother() {
      if (replacementConnectionId == null && context.canPop()) {
        context.pop();
        return;
      }
      context.pushReplacementNamed(
        AppRoutes.protocols.name,
        queryParameters: {'returnTo': ?returnTo},
      );
    }

    final providerLabel = _providerLabel(context, providerType);

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
          capturer: PlatformOAuthCallbackCapturer.forCurrentPlatform(),
        );
        credentialRef = await authorization.authorize(
          config: authorizationConfig,
          callbackReceiver: oauthCallbackLinkReceiver,
        );
        if (!context.mounted) return;
        final selectedRootId = await _selectRemoteFolder(
          context: context,
          providerType: providerType,
          baiduAppFolder: baiduAppFolder,
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
        if (context.mounted) leaveConnectionEditor(context, returnTo);
      } on OAuthAuthorizationCancelledException {
        // The user closed the sign-in sheet; nothing to report.
      } on OAuthRedirectUnsupportedException {
        if (context.mounted) {
          showPlatformMessage(
            context,
            syncText(
              context,
              '这台设备暂时不能用自己的 $providerLabel 应用密钥登录，目前只支持 iPhone 和 iPad。',
              'Signing in with your own $providerLabel app key is not available on this device yet. It currently works on iPhone and iPad.',
            ),
          );
        }
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

    final provider = _providerLabel(context, providerType);
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
          child: userRegistration.isLoading
              ? const Center(child: AdaptiveSpinner())
              : config == null || editingOwnKey.value
              ? _OwnRegistrationSetup(
                  providerType: providerType,
                  initial: ownRegistration,
                  // Only a first-time setup explains the missing key; editing
                  // an existing one is reached from the sign-in page.
                  explainsMissingKey: config == null,
                  onSave: saveOwnRegistration,
                  onCancel: config == null
                      ? null
                      : () => editingOwnKey.value = false,
                  onChooseAnother: chooseAnother,
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
                          _OwnRegistrationSummary(
                            providerType: providerType,
                            registration: ownRegistration,
                            onEdit: () => editingOwnKey.value = true,
                            onRemove: removeOwnRegistration,
                          ),
                          const SizedBox(height: 16),
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
  required String baiduAppFolder,
  required CredentialStore credentialStore,
  required OAuthRemoteTargetConfig target,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _OAuthFolderPickerSheet(
    providerType: providerType,
    baiduAppFolder: baiduAppFolder,
    picker: OAuthRemoteFolderPicker(credentialStore: credentialStore),
    target: target,
  ),
);

class _OAuthFolderPickerSheet extends StatefulWidget {
  const _OAuthFolderPickerSheet({
    required this.providerType,
    required this.baiduAppFolder,
    required this.picker,
    required this.target,
  });

  final RemoteProviderType providerType;
  final String baiduAppFolder;
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
    // Google and Baidu start at the top so their app folder can be offered.
    _parentId =
        widget.providerType == RemoteProviderType.googleDrive ||
            widget.providerType == RemoteProviderType.baiduNetdisk
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
            // Baidu only lets third-party apps write inside /apps/<app name>.
            if (widget.providerType == RemoteProviderType.baiduNetdisk &&
                _parentId == null)
              ListTile(
                key: const Key('oauth-baidu-app-folder'),
                leading: const Icon(Icons.lock_outline),
                title: Text(
                  syncText(context, 'Sync 专用文件夹', 'Sync’s app folder'),
                ),
                subtitle: Text(
                  syncText(
                    context,
                    '推荐。百度网盘只允许第三方应用写入“我的应用数据”里的专属文件夹：${widget.baiduAppFolder}',
                    'Recommended. Baidu Netdisk only lets third-party apps write to their own folder: ${widget.baiduAppFolder}',
                  ),
                ),
                onTap: () => Navigator.pop(context, widget.baiduAppFolder),
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
                          syncText(
                            context,
                            '无法读取文件夹：${AppFormat.errorSummary(snapshot.error?.toString(), context: context)}',
                            'Could not read folders: ${AppFormat.errorSummary(snapshot.error?.toString(), context: context)}',
                          ),
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

/// Setup for the user's own app registration on a provider's developer
/// platform. Everything entered here stays in platform secure storage.
class _OwnRegistrationSetup extends HookWidget {
  const _OwnRegistrationSetup({
    required this.providerType,
    required this.initial,
    required this.explainsMissingKey,
    required this.onSave,
    required this.onCancel,
    required this.onChooseAnother,
  });

  final RemoteProviderType providerType;
  final OAuthClientRegistration? initial;
  final bool explainsMissingKey;
  final Future<bool> Function(OAuthClientRegistration) onSave;
  final VoidCallback? onCancel;
  final VoidCallback onChooseAnother;

  @override
  Widget build(BuildContext context) {
    final provider = _providerLabel(context, providerType);
    final clientId = useTextEditingController(text: initial?.clientId);
    final secret = useTextEditingController(text: initial?.clientSecret);
    final appFolder = useTextEditingController(text: initial?.appFolderName);
    final error = useState<String?>(null);
    final saving = useState(false);
    final acceptsSecret = OAuthClientRegistration.acceptsSecret(providerType);
    final requiresSecret = OAuthClientRegistration.requiresSecret(providerType);
    final needsAppFolder = OAuthClientRegistration.acceptsAppFolderName(
      providerType,
    );
    final isGoogle = providerType == RemoteProviderType.googleDrive;
    final copyValue = isGoogle
        ? OAuthPublicClientConfiguration.appleBundleId
        : OAuthPublicClientConfiguration.redirectUri.toString();
    final idLabel = switch (providerType) {
      RemoteProviderType.baiduNetdisk => 'AppKey',
      RemoteProviderType.aliyunDrive => 'App ID',
      RemoteProviderType.oneDrive => syncText(
        context,
        '应用程序（客户端）ID',
        'Application (client) ID',
      ),
      _ => 'Client ID',
    };
    final secretLabel = switch (providerType) {
      RemoteProviderType.baiduNetdisk => 'SecretKey',
      _ => syncText(context, 'App Secret（可选）', 'App Secret (optional)'),
    };

    Future<void> save() async {
      if (needsAppFolder && appFolder.text.trim().isEmpty) {
        error.value = syncText(
          context,
          '请填写你在百度开放平台注册的应用名称。',
          'Enter the app name you registered on the Baidu developer platform.',
        );
        return;
      }
      final OAuthClientRegistration registration;
      try {
        registration = OAuthClientRegistration.normalized(
          type: providerType,
          clientId: clientId.text,
          clientSecret: acceptsSecret ? secret.text : null,
          appFolderName: needsAppFolder ? appFolder.text : null,
        );
      } on FormatException catch (invalid) {
        error.value = switch (invalid.message) {
          'oauth.registration.secret_missing' => syncText(
            context,
            '请填写 $secretLabel。',
            'Enter the $secretLabel.',
          ),
          'oauth.registration.secret_invalid' => syncText(
            context,
            '$secretLabel 不能包含空格。',
            'The $secretLabel cannot contain spaces.',
          ),
          'oauth.registration.google_client_id_invalid' => syncText(
            context,
            'Google 的 Client ID 以 .apps.googleusercontent.com 结尾，请从 iOS 类型的 OAuth 客户端里复制。',
            'A Google Client ID ends in .apps.googleusercontent.com. Copy it from an iOS-type OAuth client.',
          ),
          'oauth.registration.app_folder_invalid' => syncText(
            context,
            '应用名称不能包含 / 或 \\，且不能超过 64 个字符。',
            'The app name cannot contain / or \\ and must be at most 64 characters.',
          ),
          _ => syncText(
            context,
            '请填写 $idLabel，不能包含空格。',
            'Enter the $idLabel without spaces.',
          ),
        };
        return;
      }
      error.value = null;
      saving.value = true;
      final saved = await onSave(registration);
      if (!context.mounted) return;
      saving.value = false;
      if (!saved) {
        error.value = syncText(
          context,
          '无法保存应用密钥，请重试。',
          'Could not save the app key. Please retry.',
        );
      }
    }

    return ListView(
      key: const Key('oauth-own-key-form'),
      padding: const EdgeInsets.all(AppSpacing.page),
      children: [
        const SizedBox(height: 12),
        const Icon(CupertinoIcons.person_crop_circle_badge_checkmark, size: 40),
        const SizedBox(height: 20),
        Text(
          explainsMissingKey
              ? syncText(
                  context,
                  '用你自己的应用密钥连接 $provider',
                  'Connect $provider with your own app key',
                )
              : syncText(context, '$provider 应用密钥', '$provider app key'),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          explainsMissingKey
              ? isGoogle
                    ? syncText(
                        context,
                        '在 Google Cloud Console 免费创建一个自己的 OAuth 客户端，类型选「iOS」，软件包 ID 填下面这一行，再把得到的 Client ID 填进来。登录、授权都用你自己的客户端完成，额度也属于你自己；你的账号密码不会交给 Sync。',
                        'Create your own OAuth client for free in Google Cloud Console: choose the “iOS” type, set its bundle ID to the line below, and enter the Client ID it gives you. Sign-in and quota then belong to your own client; your account password is never given to Sync.',
                      )
                    : syncText(
                        context,
                        '在 $provider 开放平台免费注册一个自己的应用，把回调地址设为下面这一行，再把得到的密钥填进来。登录、授权都用你自己的应用完成，你的账号密码不会交给 Sync。',
                        'Register your own app for free on the $provider developer platform, set its redirect URI to the line below, and enter the key it gives you. Sign-in then goes through your own app; your account password is never given to Sync.',
                      )
              : syncText(
                  context,
                  '修改后，新的登录会使用这里的密钥。已经连接的位置继续使用它们登录时的密钥。',
                  'New sign-ins use the key saved here. Existing connections keep using the key they signed in with.',
                ),
          style: TextStyle(color: context.appSecondaryLabel, height: 1.5),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AdaptiveTextButton(
            key: const Key('oauth-own-help'),
            padding: EdgeInsets.zero,
            onPressed: () => context.pushNamed(
              AppRoutes.connectionHelp.name,
              queryParameters: {'provider': providerType.name},
            ),
            child: Text(syncText(context, '查看注册步骤', 'See how to register')),
          ),
        ),
        const SizedBox(height: 12),
        // Google derives the redirect from the Client ID; what it needs
        // from the user is the bundle ID of the "iOS" client instead.
        Text(
          isGoogle
              ? syncText(context, '软件包 ID', 'Bundle ID')
              : syncText(context, '回调地址', 'Redirect URI'),
          style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                key: Key(isGoogle ? 'oauth-bundle-id' : 'oauth-redirect-uri'),
                copyValue,
                style: AppType.mono,
              ),
            ),
            AdaptiveIconButton(
              icon: const Icon(CupertinoIcons.doc_on_doc),
              semanticLabel: isGoogle
                  ? syncText(context, '复制软件包 ID', 'Copy bundle ID')
                  : syncText(context, '复制回调地址', 'Copy redirect URI'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: copyValue));
                if (context.mounted) {
                  showPlatformMessage(
                    context,
                    isGoogle
                        ? syncText(context, '已复制软件包 ID。', 'Bundle ID copied.')
                        : syncText(context, '已复制回调地址。', 'Redirect URI copied.'),
                  );
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('oauth-own-client-id'),
          controller: clientId,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: idLabel),
        ),
        if (acceptsSecret) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('oauth-own-secret'),
            controller: secret,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: true,
            decoration: InputDecoration(
              labelText: secretLabel,
              helperText: requiresSecret
                  ? syncText(
                      context,
                      '百度每次续期登录都需要它，所以会和这次登录一起保存在系统安全存储里。',
                      'Baidu needs it every time sign-in is renewed, so it is kept with this sign-in in secure storage.',
                    )
                  : null,
              helperMaxLines: 3,
            ),
          ),
        ],
        if (needsAppFolder) ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('oauth-own-app-folder'),
            controller: appFolder,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: syncText(context, '应用名称', 'App name'),
              helperText: syncText(
                context,
                '和百度开放平台上的应用名称完全一致。百度只允许它写入“我的应用数据”里的同名文件夹。',
                'Exactly as registered on the Baidu developer platform. Baidu only lets it write to the folder with this name under “My app data”.',
              ),
              helperMaxLines: 3,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          syncText(
            context,
            '密钥只保存在本机的系统安全存储里，不会上传，也不会写进同步数据。',
            'The key is kept only in this device’s secure storage. It is never uploaded or written into synced data.',
          ),
          style: AppType.footnote.copyWith(color: context.appSecondaryLabel),
        ),
        if (error.value != null) ...[
          const SizedBox(height: 12),
          Text(
            key: const Key('oauth-own-error'),
            error.value!,
            style: TextStyle(color: context.appDanger),
          ),
        ],
        const SizedBox(height: 22),
        AdaptiveElevatedButton(
          key: const Key('oauth-own-save'),
          onPressed: saving.value ? null : save,
          child: Text(
            syncText(
              context,
              saving.value ? '正在保存…' : '保存并继续',
              saving.value ? 'Saving…' : 'Save and continue',
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        if (onCancel != null)
          AdaptiveTextButton(
            key: const Key('oauth-own-cancel'),
            onPressed: onCancel,
            child: Text(syncText(context, '取消', 'Cancel')),
          )
        else
          AdaptiveTextButton(
            key: const Key('oauth-choose-another'),
            onPressed: onChooseAnother,
            child: Text(
              syncText(context, '选择其他保存位置', 'Choose another location'),
            ),
          ),
      ],
    );
  }
}

/// Which app key the next sign-in will use, with a way to change it.
class _OwnRegistrationSummary extends StatelessWidget {
  const _OwnRegistrationSummary({
    required this.providerType,
    required this.registration,
    required this.onEdit,
    required this.onRemove,
  });

  final RemoteProviderType providerType;
  final OAuthClientRegistration? registration;
  final VoidCallback onEdit;
  final Future<void> Function() onRemove;

  @override
  Widget build(BuildContext context) {
    final own = registration != null;
    final hasBuiltIn = OAuthPublicClientConfiguration.hasBuiltInRegistration(
      providerType,
    );
    return Column(
      key: const Key('oauth-own-key-summary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          own
              ? syncText(context, '正在使用你自己的应用密钥', 'Using your own app key')
              : syncText(
                  context,
                  '正在使用此版本内置的应用密钥',
                  'Using this build’s app key',
                ),
        ),
        Wrap(
          spacing: 8,
          children: [
            AdaptiveTextButton(
              key: const Key('oauth-own-edit'),
              padding: EdgeInsets.zero,
              onPressed: onEdit,
              child: Text(
                own
                    ? syncText(context, '修改', 'Change')
                    : syncText(context, '改用自己的应用密钥', 'Use your own app key'),
              ),
            ),
            if (own)
              AdaptiveTextButton(
                key: const Key('oauth-own-remove'),
                padding: EdgeInsets.zero,
                onPressed: onRemove,
                child: Text(
                  hasBuiltIn
                      ? syncText(
                          context,
                          '移除，改用内置密钥',
                          'Remove and use the built-in key',
                        )
                      : syncText(context, '移除', 'Remove'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

String _providerLabel(
  BuildContext context,
  RemoteProviderType providerType,
) => switch (providerType) {
  RemoteProviderType.baiduNetdisk => syncText(context, '百度网盘', 'Baidu Netdisk'),
  RemoteProviderType.aliyunDrive => syncText(context, '阿里云盘', 'Aliyun Drive'),
  _ => remoteProviderDisplayName(providerType),
};
