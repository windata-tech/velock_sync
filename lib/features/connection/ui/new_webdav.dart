import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/core/utils.dart';
import 'package:velock_sync/features/connection/model/connection_model.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class NewWebDav extends HookConsumerWidget {
  const NewWebDav({super.key, this.replacementConnectionId, this.returnTo});

  final String? replacementConnectionId;
  final String? returnTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final savedMessage = syncText(context, '连接已保存。', 'Connection saved.');
    final formKey = useMemoized(() => GlobalKey<FormState>());
    final replacement = replacementConnectionId == null
        ? const AsyncData<ConnectionModel?>(null)
        : ref.watch(connectionDetailProvider(replacementConnectionId!));
    final replacementConnection = replacement.when(
      data: (connection) => connection,
      error: (_, _) => null,
      loading: () => null,
    );
    final replacementProtocol = replacementConnection?.protocol;
    final existingWebDav = replacementProtocol is WebDavProtocolModel
        ? replacementProtocol
        : null;

    final enableHTTPS = useState(true);
    final addressController = useTextEditingController(
      text: enableHTTPS.value ? 'https://' : 'http://',
    );
    final portController = useTextEditingController();
    final userController = useTextEditingController();
    final passwordController = useTextEditingController();
    final pathController = useTextEditingController();

    final isLoading = useState(false);
    final hasPrefilled = useRef(false);

    useEffect(() {
      if (existingWebDav == null || hasPrefilled.value) return null;
      enableHTTPS.value =
          existingWebDav.protocolType == WebDavProtocolType.https;
      addressController.text = existingWebDav.address;
      portController.text = existingWebDav.port;
      userController.text = existingWebDav.username ?? '';
      pathController.text = existingWebDav.path ?? '';
      hasPrefilled.value = true;
      return null;
    }, [existingWebDav?.credentialRef]);

    useEffect(() {
      const http = 'http://';
      const https = 'https://';

      final oldValue = addressController.value;
      String newText = oldValue.text;

      if (enableHTTPS.value) {
        if (newText.startsWith(http)) {
          newText = newText.replaceFirst(http, https);
        }
      } else {
        if (newText.startsWith(https)) {
          newText = newText.replaceFirst(https, http);
        }
      }

      if (newText == oldValue.text) return null;

      final oldSelection = oldValue.selection;
      final lengthDifference = newText.length - oldValue.text.length;

      final newOffset = (oldSelection.baseOffset + lengthDifference).clamp(
        0,
        newText.length,
      );
      final newSelection = TextSelection.fromPosition(
        TextPosition(offset: newOffset),
      );

      addressController.value = TextEditingValue(
        text: newText,
        selection: newSelection,
        composing: TextRange.empty,
      );

      return null;
    }, [enableHTTPS.value]);

    Future<void> onHttpsChanged(bool value) async {
      if (value) {
        enableHTTPS.value = true;
        return;
      }
      final confirmed = await showAdaptiveConfirmation(
        context,
        title: syncText(context, '使用不安全的 HTTP？', 'Use Insecure HTTP?'),
        message: syncText(
          context,
          'HTTP 会使服务器地址、账号和传输内容面临被窃听或篡改的风险。仅在你确认服务器位于可信网络且不支持 HTTPS 时继续。',
          'HTTP exposes the server address, credentials, and transferred data to interception or tampering. Continue only if the server is on a trusted network and does not support HTTPS.',
        ),
        confirmLabel: syncText(context, '仍然使用 HTTP', 'Use HTTP Anyway'),
        cancelLabel: syncText(context, '保持 HTTPS', 'Keep HTTPS'),
        isDestructive: true,
      );
      if (confirmed == true && context.mounted) {
        enableHTTPS.value = false;
        logw('User explicitly enabled insecure WebDAV HTTP transport.');
      }
    }

    if (replacementConnectionId != null && replacement.isLoading) {
      return const Center(child: PlatformCircularProgressIndicator());
    }
    if (replacementConnectionId != null && existingWebDav == null) {
      return Center(
        child: Text(
          syncText(
            context,
            '要编辑的 WebDAV 连接不可用。',
            'The WebDAV connection to edit is unavailable.',
          ),
        ),
      );
    }

    return PlatformScaffold(
      iosContentPadding: false,
      appBar: WDAppBar(
        leading: PlatformIconButton(
          padding: EdgeInsets.zero,
          cupertino: (context, platform) =>
              CupertinoIconButtonData(icon: const Icon(CupertinoIcons.back)),
          material: (context, platform) =>
              MaterialIconButtonData(icon: const Icon(Icons.arrow_back)),
          onPressed: () => context.pop(),
        ),
        title: Text(
          existingWebDav == null
              ? syncText(context, '新建 WebDAV 连接', 'New WebDAV Connection')
              : syncText(context, '编辑 WebDAV 连接', 'Edit WebDAV Connection'),
        ),
        trailingActions: [
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: () => context.pushNamed(
              AppRoutes.connectionHelp.name,
              queryParameters: {'provider': RemoteProviderType.webDav.name},
            ),
            child: Text(
              syncText(context, '说明', 'Help'),
              style: TextStyle(color: context.appSecondaryLabel),
            ),
          ),
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: isLoading.value
                ? null
                : () async {
                    final isValidate = formKey.currentState?.validate();
                    if (isValidate == true) {
                      String? createdCredentialRef;
                      var connectionPersisted = false;
                      isLoading.value = true;
                      try {
                        if (passwordController.text.isNotEmpty) {
                          createdCredentialRef = await ref
                              .read(connectionRepositoryProvider)
                              .storeWebDavPassword(passwordController.text);
                        }
                        final protocolModel = WebDavProtocolModel(
                          protocolType: enableHTTPS.value
                              ? WebDavProtocolType.https
                              : WebDavProtocolType.http,
                          address: addressController.text,
                          port: portController.text,
                          username: userController.text.isNotEmpty
                              ? userController.text
                              : null,
                          credentialRef:
                              createdCredentialRef ??
                              existingWebDav?.credentialRef,
                          path: pathController.text.isNotEmpty
                              ? pathController.text
                              : null,
                        );
                        // Use the plain probe instead of
                        // `protocolConnectCheckerProvider(...).future`: that
                        // autoDispose provider can be disposed while the await
                        // is pending (Riverpod 3 UnmountedRefException), which
                        // used to land here in the catch and delete the
                        // just-stored password even though the connection was
                        // already saved.
                        final isConnected =
                            await ref.read(protocolConnectionProbeProvider)(
                              credentials: ref.read(credentialStoreProvider),
                              protocol: protocolModel,
                            );
                        if (isConnected) {
                          if (replacementConnection != null) {
                            await ref
                                .read(connectionsProvider.notifier)
                                .replaceWebDavConnection(
                                  connectionId: replacementConnection.id,
                                  protocol: protocolModel,
                                );
                          } else {
                            final connectionCreation = ref.read(
                              connectionCreationProvider.notifier,
                            );
                            await connectionCreation.setProtocolAndFinalize(
                              protocolModel: protocolModel,
                            );
                          }
                          connectionPersisted = true;
                          if (context.mounted) {
                            context.go(returnTo ?? AppRoutes.connections.path);
                          } else {
                            Fluttertoast.showToast(msg: savedMessage);
                          }
                        } else {
                          await ref
                              .read(connectionRepositoryProvider)
                              .deleteCredential(createdCredentialRef);
                          if (context.mounted) {
                            Fluttertoast.showToast(
                              msg: syncText(
                                context,
                                '连接测试失败：请检查地址、端口、账号密码。',
                                'Connection test failed. Check the address, port, username, and password.',
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        // A connection may already be durably saved by the time
                        // an exception reaches this handler, so never delete
                        // the fresh credential just because the flow aborted.
                        // It is removed only when the probe explicitly failed
                        // above (nothing was persisted) or, below, only when
                        // we know this flow never persisted anything.
                        if (!connectionPersisted) {
                          try {
                            await ref
                                .read(connectionRepositoryProvider)
                                .deleteCredential(createdCredentialRef);
                          } on Object {
                            // Keep the original error as the actionable one.
                          }
                        }
                        loge('连接失败: ${e.runtimeType}');
                        if (context.mounted) {
                          Fluttertoast.showToast(
                            msg: connectionPersisted
                                ? syncText(
                                    context,
                                    '连接已保存，但状态检查未完成。',
                                    'Connection saved, but the status check did not finish.',
                                  )
                                : syncText(
                                    context,
                                    '连接保存失败，请重试。',
                                    'Unable to save connection. Please try again.',
                                  ),
                          );
                        }
                        return;
                      } finally {
                        isLoading.value = false;
                      }
                      logd('WebDAV connection creation finished.');
                      // protocol.setProtocol(ProtocolModel.webDav(protocolType: WebDavProtocolType.http, address: address, port: port))
                    }
                  },
            child: isLoading.value
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    syncText(context, '保存', 'Save'),
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        child: Column(
          children: [
            Form(
              key: formKey,
              child: _WebDavFormFields(
                enableHTTPS: enableHTTPS.value,
                addressController: addressController,
                portController: portController,
                userController: userController,
                passwordController: passwordController,
                pathController: pathController,
                passwordOptional: existingWebDav?.credentialRef != null,
                onEnableHTTPSChanged: onHttpsChanged,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PrefixWrapper extends StatelessWidget {
  final Widget child;

  const PrefixWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: 112, child: child);
  }
}

class _WebDavFormFields extends StatelessWidget {
  final TextEditingController addressController;
  final TextEditingController portController;
  final TextEditingController userController;
  final TextEditingController passwordController;
  final TextEditingController pathController;
  final bool enableHTTPS;
  final bool passwordOptional;
  final ValueChanged<bool> onEnableHTTPSChanged;

  const _WebDavFormFields({
    required this.addressController,
    required this.portController,
    required this.userController,
    required this.passwordController,
    required this.pathController,
    required this.enableHTTPS,
    required this.passwordOptional,
    required this.onEnableHTTPSChanged,
  });

  @override
  Widget build(BuildContext context) {
    final formChildren = [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text(syncText(context, '启用 HTTPS', 'Enable HTTPS')),
            Spacer(),
            Semantics(
              label: syncText(context, '启用 HTTPS', 'Enable HTTPS'),
              identifier: 'webdav_https',
              child: PlatformSwitch(
                value: enableHTTPS,
                onChanged: onEnableHTTPSChanged,
              ),
            ),
          ],
        ),
      ),
      PlatformTextFormField(
        key: const ValueKey('webdav_address'),
        controller: addressController,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return syncText(context, '请输入服务器地址', 'Enter a server address');
          }
          if (!isUrl(value, protocols: ['http', 'https'])) {
            return syncText(
              context,
              '请输入有效的服务器地址',
              'Enter a valid server address',
            );
          }
          final expectedScheme = enableHTTPS ? 'https://' : 'http://';
          if (!value.toLowerCase().startsWith(expectedScheme)) {
            return enableHTTPS
                ? syncText(
                    context,
                    '启用 HTTPS 时地址必须以 https:// 开头',
                    'The address must start with https:// when HTTPS is enabled',
                  )
                : syncText(
                    context,
                    '使用 HTTP 时地址必须以 http:// 开头',
                    'The address must start with http:// when using HTTP',
                  );
          }
          return null;
        },
        hintText: syncText(
          context,
          '例如：https://example.com/webdav',
          'e.g. https://example.com/webdav',
        ),
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(
              labelText: syncText(context, '服务器地址', 'Server Address'),
            ),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(
              child: Text(syncText(context, '服务器地址', 'Server Address')),
            ),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
      PlatformTextFormField(
        key: const ValueKey('webdav_port'),
        controller: portController,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return syncText(context, '请输入端口', 'Enter a port');
          }
          return null;
        },
        hintText: syncText(context, '例如：8888', 'e.g. 8888'),
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(
              labelText: syncText(context, '端口', 'Port'),
            ),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(child: Text(syncText(context, '端口', 'Port'))),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
    ];

    final formOptionalChildren = [
      PlatformTextFormField(
        key: const ValueKey('webdav_path'),
        controller: pathController,
        validator: (value) {
          return null;
        },
        maxLines: 1,
        hintText: syncText(
          context,
          '例如：/ 或者 /path/to/webdav',
          'e.g. / or /path/to/webdav',
        ),
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(
              labelText: syncText(context, '子路径', 'Subpath'),
            ),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(
              child: Text(syncText(context, '子路径', 'Subpath')),
            ),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
      PlatformTextFormField(
        key: const ValueKey('webdav_user'),
        controller: userController,
        validator: (value) {
          if (passwordController.text.isNotEmpty &&
              (value == null || value.isEmpty)) {
            return syncText(context, '请输入用户名', 'Enter a username');
          }
          return null;
        },
        hintText: syncText(context, '请输入用户名', 'Enter a username'),
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(
              labelText: syncText(context, '用户名', 'Username'),
            ),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(
              child: Text(syncText(context, '用户名', 'Username')),
            ),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
      PlatformTextFormField(
        key: const ValueKey('webdav_password'),
        controller: passwordController,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        validator: (value) {
          if (userController.text.isNotEmpty &&
              !passwordOptional &&
              (value == null || value.isEmpty)) {
            return syncText(context, '请输入密码', 'Enter a password');
          }
          return null;
        },
        hintText: passwordOptional
            ? syncText(
                context,
                '留空则保留原密码',
                'Leave blank to keep the current password',
              )
            : syncText(context, '请输入密码', 'Enter a password'),
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(
              labelText: syncText(context, '密码', 'Password'),
            ),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(
              child: Text(syncText(context, '密码', 'Password')),
            ),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
    ];

    return Column(
      children: [
        AdaptiveListSection(
          header: syncText(context, '基本信息', 'Basic Information'),
          children: formChildren,
        ),
        AdaptiveListSection(
          header: syncText(context, '选填信息', 'Optional Information'),
          children: formOptionalChildren,
        ),
      ],
    );
  }
}
