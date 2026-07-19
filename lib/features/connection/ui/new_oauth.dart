import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
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
      registrationError = error;
    }

    Future<void> authorizeAndSave() async {
      if (config == null || formKey.currentState?.validate() != true) return;
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
          config: config,
          callbackReceiver: oauthCallbackLinkReceiver,
        );
        if (!context.mounted) return;
        final selectedRootId = await _selectRemoteFolder(
          context: context,
          providerType: providerType,
          credentialStore: ref.read(credentialStoreProvider),
          target: OAuthRemoteTargetConfig(
            providerType: providerType,
            clientId: config.clientId,
            credentialRef: credentialRef,
            rootId: rootController.text.trim(),
          ),
        );
        if (selectedRootId == null) return;
        rootController.text = selectedRootId;
        final protocol = ProtocolModel.oauth(
          providerType: providerType,
          clientId: config.clientId,
          credentialRef: credentialRef,
          rootId: selectedRootId,
          accountLabel: accountController.text.trim().isEmpty
              ? null
              : accountController.text.trim(),
        );
        final connected = await ref.read(
          protocolConnectCheckerProvider(protocol).future,
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('授权或连接检查失败：${error.runtimeType}')),
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

    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text(
          '${replacementConnectionId == null ? '连接' : '重新授权'} ${_providerLabel(providerType)}',
        ),
        trailingActions: [
          PlatformTextButton(
            onPressed: config == null || isLoading.value
                ? null
                : authorizeAndSave,
            child: isLoading.value
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(replacementConnectionId == null ? '授权并保存' : '重新授权'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: config == null
            ? _MissingOAuthRegistration(
                providerType: providerType,
                error: registrationError,
              )
            : Form(
                key: formKey,
                child: ListView(
                  children: [
                    Text(
                      '将使用系统浏览器完成 PKCE 授权。Refresh Token 仅写入系统安全存储。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
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
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: accountController,
                      decoration: const InputDecoration(
                        labelText: '账号显示名称（可选）',
                      ),
                    ),
                  ],
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
  });

  final RemoteProviderType providerType;
  final Object? error;

  @override
  Widget build(BuildContext context) => Text(
    '未配置 ${_providerLabel(providerType)} 的公开 OAuth Client ID。\n\n'
    '请使用 --dart-define=${providerType == RemoteProviderType.googleDrive ? 'GOOGLE_OAUTH_CLIENT_ID' : 'ONEDRIVE_OAUTH_CLIENT_ID'}=<client-id> 构建，并在 Provider 控制台登记回调地址 velocksync://oauth/callback。\n\n'
    '配置错误：${error.runtimeType}',
  );
}

String _providerLabel(RemoteProviderType providerType) =>
    switch (providerType) {
      RemoteProviderType.googleDrive => 'Google Drive',
      RemoteProviderType.oneDrive => 'OneDrive',
      RemoteProviderType.baiduNetdisk => '百度网盘',
      RemoteProviderType.aliyunDrive => '阿里云盘',
      RemoteProviderType.webDav => 'WebDAV',
    };
