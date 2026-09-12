import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
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
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/app_components.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

/// Creates a Google Drive or OneDrive connection through system-browser PKCE.
/// It deliberately never renders, stores, or logs an access/refresh token.
class NewOAuthConnection extends HookConsumerWidget {
  const NewOAuthConnection({
    super.key,
    required this.providerType,
    this.replacementConnectionId,
  });

  final RemoteProviderType providerType;
  final String? replacementConnectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formKey = useMemoized(GlobalKey<FormState>.new);
    final localDataManager = ref.read(localDataManagerProvider);
    final clientIdController = useTextEditingController();
    final savedClientId = useFuture(
      useMemoized(
        () => localDataManager.getStringAsync(_oauthClientIdKey(providerType)),
        [providerType],
      ),
    );
    useListenable(clientIdController);
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
      final clientId = clientIdController.text.trim();
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
        showPlatformMessage(context, '请输入公开 OAuth Client ID。');
        return;
      }
      await localDataManager.setStringAsync(
        _oauthClientIdKey(providerType),
        clientId,
      );
      if (context.mounted) {
        showPlatformMessage(context, 'Client ID 已保存，可以开始授权。');
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
        final connected = await probeProtocolConnection(
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
        if (context.mounted) context.goNamed(AppRoutes.connections.name);
      } on Object catch (error) {
        if (context.mounted) {
          showPlatformMessage(context, '授权或连接检查失败：${error.runtimeType}');
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

    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text(
          '${replacementConnectionId == null ? '连接' : '重新授权'} ${_providerLabel(providerType)}',
        ),
        trailingActions: [
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: () => context.pushNamed(
              AppRoutes.connectionHelp.name,
              queryParameters: {'provider': providerType.name},
            ),
            child: const Text('说明'),
          ),
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: config == null || isLoading.value
                ? null
                : authorizeAndSave,
            child: isLoading.value
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(replacementConnectionId == null ? '保存' : '重授权'),
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
                  onSave: saveClientId,
                )
              : Form(
                  key: formKey,
                  child: ListView(
                    padding: const EdgeInsets.only(
                      top: AppSpacing.md,
                      bottom: AppSpacing.xl,
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.page,
                          0,
                          AppSpacing.page,
                          AppSpacing.sm,
                        ),
                        child: Text(
                          '将使用系统浏览器完成安全授权。Refresh Token 仅写入系统安全存储。',
                          style: TextStyle(
                            color: context.appSecondaryLabel,
                            height: 1.4,
                          ),
                        ),
                      ),
                      AdaptiveListSection(
                        header: '远端空间',
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.md,
                              AppSpacing.md,
                              AppSpacing.md,
                              AppSpacing.sm,
                            ),
                            child: TextFormField(
                              controller: rootController,
                              decoration: const InputDecoration(
                                labelText: '远端根目录 ID',
                                helperText:
                                    'Google 默认 appDataFolder；OneDrive 可填写已选目录 ID。',
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '请输入远端根目录 ID'
                                  : null,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppSpacing.md,
                              AppSpacing.sm,
                              AppSpacing.md,
                              AppSpacing.md,
                            ),
                            child: TextFormField(
                              controller: accountController,
                              decoration: const InputDecoration(
                                labelText: '账号显示名称（可选）',
                              ),
                            ),
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
              title: const Text('选择远端同步位置'),
              subtitle: Text(_parentId == null ? '根目录' : '当前文件夹'),
              leading: _history.isEmpty
                  ? const Icon(Icons.folder_outlined)
                  : IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => _goTo(_history.removeLast()),
                    ),
              trailing: TextButton(
                onPressed: () => Navigator.pop(context, selectedId),
                child: const Text('选择当前目录'),
              ),
            ),
            if (widget.providerType == RemoteProviderType.googleDrive &&
                _parentId == null)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('应用专属安全空间'),
                subtitle: const Text('appDataFolder（推荐用于加密同步）'),
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
                        child: Text('无法读取文件夹：${snapshot.error.runtimeType}'),
                      ),
                    );
                  }
                  final items = snapshot.requireData;
                  if (items.isEmpty) {
                    return const Center(child: Text('当前目录没有可访问的子文件夹。'));
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
    required this.onSave,
  });

  final RemoteProviderType providerType;
  final Object? error;
  final TextEditingController clientIdController;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final provider = _providerLabel(providerType);
    final clientIdKey = providerType == RemoteProviderType.googleDrive
        ? 'GOOGLE_OAUTH_CLIENT_ID'
        : 'ONEDRIVE_OAUTH_CLIENT_ID';
    return ListView(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            0,
            AppSpacing.page,
            AppSpacing.sm,
          ),
          child: Text(
            '使用你自己的 Google Cloud / Azure 应用注册公开 Client ID，'
            '授权会在系统浏览器中完成。',
            style: AppType.footnote.copyWith(
              color: context.appSecondaryLabel,
            ),
          ),
        ),
        AdaptiveListSection(
          header: '授权配置',
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '只填写公开 Client ID，不要填写 Client Secret。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '自定义构建也可以用 --dart-define 传入 $clientIdKey；'
                '这里保存的值只写入本机配置，不包含任何用户令牌。',
                style: AppType.footnote.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '公开 Client ID',
                    style: AppType.caption.copyWith(
                      color: context.appSecondaryLabel,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  TextField(
                    key: const Key('oauth-client-id-field'),
                    controller: clientIdController,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: AppType.body,
                    decoration: const InputDecoration(
                      hintText: '例如：1234567890-abcdef.apps.googleusercontent.com',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '可在云控制台的 OAuth 客户端页面找到。',
                    style: AppType.footnote.copyWith(
                      color: context.appSecondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
            AppFormRow(
              label: '构建变量',
              child: Text(
                clientIdKey,
                style: AppType.mono.copyWith(
                  color: context.appSecondaryLabel,
                ),
              ),
            ),
            const AppFormRow(
              label: '回调地址',
              child: Text(
                'velocksync://oauth/callback',
                style: AppType.mono,
              ),
            ),
          ],
        ),
        AdaptiveListSection(
          header: '当前状态',
          footer: AppDetailDisclosure(
            detail: '${error.runtimeType}\n'
                '错误代码：${_errorCode(error)}',
          ),
          children: [
            AdaptiveListTile(
              leading: AdaptiveIconBadge(
                icon: CupertinoIcons.exclamationmark_triangle,
                color: AppTone.attention.color(context),
              ),
              title: Text(
                '$provider 授权未就绪',
                style: AppType.rowTitleStrong,
              ),
              subtitle: const Text(
                '填写并保存 Client ID 后即可继续授权。',
                maxLines: 2,
              ),
            ),
          ],
        ),
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
