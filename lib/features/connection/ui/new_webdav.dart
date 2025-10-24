import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/extensions.dart';
import 'package:velock_sync/core/logger.dart';
import 'package:velock_sync/core/utils.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/features/connection/state/connection_provider.dart';
import 'package:velock_sync/features/connection/state/protocol_provider.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

class NewWebDav extends HookConsumerWidget {
  const NewWebDav({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formKey = useMemoized(() => GlobalKey<FormState>());

    final enableHTTPS = useState(false);
    final addressController = useTextEditingController(
      text: enableHTTPS.value ? 'https://' : 'http://',
    );
    final portController = useTextEditingController();
    final userController = useTextEditingController();
    final passwordController = useTextEditingController();
    final pathController = useTextEditingController();

    final isLoading = useState(false);

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

    return PlatformScaffold(
      appBar: WDAppBar(
        title: Text('新建 WebDAV 连接'),
        trailingActions: [
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: isLoading.value
                ? null
                : () async {
                    final isValidate = formKey.currentState?.validate();
                    if (isValidate == true) {
                      final protocolModel = ProtocolModel.webDav(
                        protocolType: enableHTTPS.value
                            ? WebDavProtocolType.https
                            : WebDavProtocolType.http,
                        address: addressController.text,
                        port: portController.text,
                        username: userController.text.isNotEmpty
                            ? userController.text
                            : null,
                        password: passwordController.text.isNotEmpty
                            ? passwordController.text
                            : null,
                        path: pathController.text.isNotEmpty
                            ? pathController.text
                            : null,
                      );
                      try {
                        final checkProvider = protocolConnectCheckerProvider(
                          protocolModel,
                        );
                        isLoading.value = true;
                        final isConnected = await ref.read(
                          checkProvider.future,
                        );
                        if (isConnected) {
                          if (context.mounted) {
                            // context.pop(protocolModel);
                            // context.pushReplacementNamed(AppRoutes.connection.name, extra: protocolModel);
                            // context.goNamed(AppRoutes.connection.name, extra: protocolModel);
                            // final protocol = ref.read(protocolProvider.notifier);
                            // protocol.setProtocol(protocolModel);
                            final connectionCreation = ref.read(
                              connectionCreationProvider.notifier,
                            );
                            await connectionCreation.setProtocolAndFinalize(
                              protocolModel: protocolModel,
                            );
                            if (context.mounted) {
                              context.goNamed(AppRoutes.connections.name);
                            } else {
                              Fluttertoast.showToast(
                                msg:
                                    'context is not mounted, cannot navigate to connection page',
                              );
                            }
                          }
                        }
                        // if (isConnected) {
                        //   if (context.mounted) {
                        //     ScaffoldMessenger.of(context).showSnackBar(
                        //       const SnackBar(content: Text('连接成功'), backgroundColor: Colors.green),
                        //     );
                        //   }
                        // } else {
                        //   if (context.mounted) {
                        //     ScaffoldMessenger.of(context).showSnackBar(
                        //       const SnackBar(content: Text('连接失败，请检查配置'), backgroundColor: Colors.orange),
                        //     );
                        //   }
                        // }
                      } catch (e, stackTrace) {
                        loge('连接失败: $e', stackTrace: stackTrace);
                        return;
                      } finally {
                        isLoading.value = false;
                      }
                      logd(
                        'address: ${addressController.text}, user: ${userController.text}, password: ${passwordController.text}, port: ${portController.text}, path: ${pathController.text}, enableHTTPS: ${enableHTTPS.value}',
                      );
                      // protocol.setProtocol(ProtocolModel.webDav(protocolType: WebDavProtocolType.http, address: address, port: port))
                    }
                  },
            child: isLoading.value
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('保存'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(0),
        child: Form(
          key: formKey,
          child: _WebDavFormFields(
            enableHTTPS: enableHTTPS.value,
            addressController: addressController,
            portController: portController,
            userController: userController,
            passwordController: passwordController,
            pathController: pathController,
            onEnableHTTPSChanged: (bool value) {
              enableHTTPS.value = value;
              logd('enableHTTPS: $value');
            },
          ),
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
    return SizedBox(width: 95, child: child);
  }
}

class _WebDavFormFields extends StatelessWidget {
  final TextEditingController addressController;
  final TextEditingController portController;
  final TextEditingController userController;
  final TextEditingController passwordController;
  final TextEditingController pathController;
  final bool enableHTTPS;
  final ValueChanged<bool> onEnableHTTPSChanged;

  const _WebDavFormFields({
    required this.addressController,
    required this.portController,
    required this.userController,
    required this.passwordController,
    required this.pathController,
    required this.enableHTTPS,
    required this.onEnableHTTPSChanged,
  });

  @override
  Widget build(BuildContext context) {
    final formChildren = [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text('是否启用Https'),
            Spacer(),
            PlatformSwitch(value: enableHTTPS, onChanged: onEnableHTTPSChanged),
          ],
        ),
      ),
      PlatformTextFormField(
        controller: addressController,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return '请输入服务器地址';
          }
          if (!isUrl(value, protocols: ['http', 'https'])) {
            return '请输入有效的服务器地址';
          }
          return null;
        },
        hintText: '例如：https://example.com/webdav',
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(labelText: '服务器地址'),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(child: const Text('服务器地址')),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
      PlatformTextFormField(
        controller: portController,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return '请输入端口';
          }
          return null;
        },
        hintText: '例如：8888',
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(labelText: '端口'),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(child: const Text('端口')),
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
        controller: pathController,
        validator: (value) {
          return null;
        },
        maxLines: 1,
        hintText: '例如：/ 或者 /path/to/webdav',
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(labelText: '子路径'),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(child: const Text('子路径')),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
      PlatformTextFormField(
        controller: userController,
        validator: (value) {
          if (passwordController.text.isNotEmpty &&
              (value == null || value.isEmpty)) {
            return '请输入用户名';
          }
          return null;
        },
        hintText: '请输入用户名',
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(labelText: '用户名'),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(child: const Text('用户名')),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
      PlatformTextFormField(
        controller: passwordController,
        validator: (value) {
          if (userController.text.isNotEmpty &&
              (value == null || value.isEmpty)) {
            return '请输入密码';
          }
          return null;
        },
        hintText: '请输入密码',
        material: (context, platform) {
          return MaterialTextFormFieldData(
            decoration: InputDecoration(labelText: '密码'),
          );
        },
        cupertino: (context, platform) {
          return CupertinoTextFormFieldData(
            prefix: PrefixWrapper(child: const Text('密码')),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // decoration: BoxDecoration(
            //   border: Border.all(color: context.dividerColor),
            //   borderRadius: BorderRadius.circular(8),
            // ),
          );
        },
      ),
    ];

    return Platform.isIOS
        ? Column(
            children: [
              CupertinoFormSection.insetGrouped(
                backgroundColor: context.groupedBackgroundColor,
                header: const Text('基本信息'),
                children: formChildren,
              ),
              CupertinoFormSection.insetGrouped(
                backgroundColor: context.groupedBackgroundColor,
                header: const Text('选填信息'),
                children: formOptionalChildren,
              ),
            ],
          )
        : Column(children: [...formChildren, ...formOptionalChildren]);
  }
}
