import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/core/app_router.dart';
import 'package:velock_sync/core/state/common.dart';
import 'package:velock_sync/providers/baidu_netdisk/baidu_netdisk_credentials.dart';
import 'package:velock_sync/widgets/adaptive_widgets.dart';
import 'package:velock_sync/widgets/common_widgets.dart';

/// Stores a manually obtained Baidu Netdisk OAuth bundle in secure storage.
///
/// This is intentionally not a connection wizard. The repository does not
/// yet ship a Baidu [RemoteObjectStore], so saving these credentials must not
/// pretend to create a usable sync target.
class NewBaiduToken extends HookConsumerWidget {
  const NewBaiduToken({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formKey = useMemoized(GlobalKey<FormState>.new);
    final appKeyController = useTextEditingController();
    final secretKeyController = useTextEditingController();
    final accessTokenController = useTextEditingController();
    final refreshTokenController = useTextEditingController();
    final expiresAtController = useTextEditingController();
    final scopesController = useTextEditingController(text: 'basic,netdisk');
    final isSaving = useState(false);
    final hasPrefilled = useRef(false);
    final savedCredentials = useFuture(
      useMemoized(
        () => ref.read(credentialStoreProvider).readBaiduNetdiskCredentials(),
      ),
    );

    useEffect(() {
      final credentials = savedCredentials.data;
      if (credentials == null || hasPrefilled.value) return null;
      appKeyController.text = credentials.appKey;
      secretKeyController.text = credentials.secretKey ?? '';
      accessTokenController.text = credentials.accessToken;
      refreshTokenController.text = credentials.refreshToken ?? '';
      expiresAtController.text = credentials.expiresAt?.toIso8601String() ?? '';
      scopesController.text = credentials.scopes.join(',');
      hasPrefilled.value = true;
      return null;
    }, [savedCredentials.data]);

    Future<void> saveCredentials() async {
      if (formKey.currentState?.validate() != true) return;
      isSaving.value = true;
      try {
        final expiryText = expiresAtController.text.trim();
        final expiresAt = expiryText.isEmpty
            ? null
            : DateTime.tryParse(expiryText)?.toUtc();
        if (expiryText.isNotEmpty && expiresAt == null) {
          throw const FormatException('过期时间格式无效');
        }
        final scopes = scopesController.text
            .split(RegExp(r'[ ,]+'))
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet();
        if (!scopes.contains('netdisk')) {
          throw const FormatException('scope 必须包含 netdisk');
        }

        await ref
            .read(credentialStoreProvider)
            .writeBaiduNetdiskCredentials(
              BaiduNetdiskCredentialBundle(
                appKey: appKeyController.text.trim(),
                secretKey: secretKeyController.text.trim().isEmpty
                    ? null
                    : secretKeyController.text.trim(),
                accessToken: accessTokenController.text.trim(),
                refreshToken: refreshTokenController.text.trim().isEmpty
                    ? null
                    : refreshTokenController.text.trim(),
                expiresAt: expiresAt,
                scopes: scopes,
              ),
            );
        if (context.mounted) {
          showPlatformMessage(context, '百度网盘凭据已保存到系统安全存储。');
          context.pop();
        }
      } on FormatException catch (error) {
        if (context.mounted) showPlatformMessage(context, error.message);
      } on Object catch (error) {
        if (context.mounted) {
          showPlatformMessage(context, '凭据保存失败：${error.runtimeType}');
        }
      } finally {
        isSaving.value = false;
      }
    }

    return PlatformScaffold(
      appBar: WDAppBar(
        title: const Text('配置百度网盘 Token'),
        trailingActions: [
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: () => context.pushNamed(
              AppRoutes.connectionHelp.name,
              queryParameters: {'provider': 'baiduNetdisk'},
            ),
            child: const Text('说明'),
          ),
          PlatformTextButton(
            padding: EdgeInsets.zero,
            onPressed: isSaving.value ? null : saveCredentials,
            child: isSaving.value
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Material(
        type: MaterialType.transparency,
        child: Form(
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
                  '这里保存的是百度 OAuth 凭据，不会创建可同步连接。当前项目尚未接入百度网盘对象存储适配器；保存后可供后续适配器或受信任的 Token Broker 使用。',
                  style: TextStyle(
                    color: context.appSecondaryLabel,
                    height: 1.45,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  0,
                  AppSpacing.page,
                  AppSpacing.md,
                ),
                child: Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.xs,
                  children: [
                    PlatformTextButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => launchUrl(
                        Uri.parse(
                          'https://pan.baidu.com/union/console/applist?from=doc_header',
                        ),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: const Text('打开百度开放平台控制台'),
                    ),
                    PlatformTextButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => context.pushNamed(
                        AppRoutes.connectionHelp.name,
                        queryParameters: {'provider': 'baiduNetdisk'},
                      ),
                      child: const Text('查看填写说明'),
                    ),
                  ],
                ),
              ),
              AdaptiveListSection(
                header: '应用信息',
                children: [
                  _BaiduField(
                    controller: appKeyController,
                    label: 'AppKey',
                    helperText: '百度控制台创建应用后得到的应用标识。',
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入 AppKey'
                        : null,
                  ),
                  _BaiduField(
                    controller: secretKeyController,
                    label: 'SecretKey（可选）',
                    helperText:
                        '设备码换 Token 和刷新 Token 时需要；简化模式只粘贴 Access Token 时可留空。',
                    obscureText: true,
                  ),
                ],
              ),
              AdaptiveListSection(
                header: '令牌',
                children: [
                  _BaiduField(
                    controller: accessTokenController,
                    label: 'Access Token',
                    helperText: '必填。不要把它发送给他人，也不要放进截图、同步包或普通日志。',
                    obscureText: true,
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入 Access Token'
                        : null,
                  ),
                  _BaiduField(
                    controller: refreshTokenController,
                    label: 'Refresh Token（可选）',
                    helperText: '授权码/设备码模式通常会返回；百度要求每次刷新后使用新返回的 refresh_token。',
                    obscureText: true,
                  ),
                  _BaiduField(
                    controller: expiresAtController,
                    label: 'Access Token 过期时间（可选）',
                    helperText: 'ISO 8601，例如 2026-08-07T12:00:00Z；不知道时可以留空。',
                    keyboardType: TextInputType.datetime,
                  ),
                  _BaiduField(
                    controller: scopesController,
                    label: 'Scope',
                    helperText: '用逗号或空格分隔，至少包含 basic,netdisk。',
                    validator: (value) =>
                        value == null ||
                            !value.split(RegExp(r'[ ,]+')).contains('netdisk')
                        ? 'Scope 必须包含 netdisk'
                        : null,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.sm,
                  AppSpacing.page,
                  0,
                ),
                child: Text(
                  savedCredentials.data == null
                      ? '凭据尚未配置。'
                      : '当前设备已有一组百度凭据；再次保存会覆盖原配置。',
                  style: TextStyle(
                    color: context.appSecondaryLabel,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BaiduField extends StatelessWidget {
  const _BaiduField({
    required this.controller,
    required this.label,
    required this.helperText,
    this.validator,
    this.obscureText = false,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String helperText;
  final String? Function(String?)? validator;
  final bool obscureText;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.md,
      0,
    ),
    child: TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        helperText: helperText,
        helperMaxLines: 3,
        helperStyle: TextStyle(
          color: context.appSecondaryLabel,
          fontSize: 12,
          height: 1.3,
        ),
        contentPadding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm,
        ),
      ),
      validator: validator,
    ),
  );
}
