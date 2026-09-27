import 'package:flutter/widgets.dart';

import 'package:velock_sync/features/connection/model/protocol_model.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

/// User-facing description of what the first-party provider adapters do — and
/// what they cannot do.
///
/// Two rules keep this honest:
///
/// * It describes behaviour the app implements for that connection type, never
///   a guess about one server, and never a protocol feature the app does not
///   use. Capability flags live in each adapter's `RemoteCapabilities`
///   (`lib/providers/*/…_object_store.dart`); no row may promise more than
///   those flags allow. WebDAV declares `supportsResumableUpload: false`, so
///   nothing here may suggest resuming an interrupted upload, and a service
///   feature the app never calls (a cloud trash, a ranged read) is not a Sync
///   feature.
/// * Every string is localized: an English sheet must not paint Chinese.
class ProviderCapabilitySummary {
  const ProviderCapabilitySummary({
    required this.providerName,
    required this.features,
    required this.limitations,
    required this.credentials,
  });

  final String providerName;
  final List<String> features;
  final List<String> limitations;

  /// How the secret behind this connection is kept. A property of the app's
  /// own storage, deliberately not listed among the connection's features.
  final String credentials;
}

/// [context] is required-but-nullable so a caller cannot forget the locale:
/// null means "no locale available" and falls back to Chinese.
ProviderCapabilitySummary providerCapabilitySummary(
  ProtocolModel protocol, {
  required BuildContext? context,
}) => switch (protocol) {
  WebDavProtocolModel() => ProviderCapabilitySummary(
    providerName: 'WebDAV',
    features: [
      _t(
        context,
        '浏览、上传和下载服务里的文件',
        'Browse, upload and download files on the service',
      ),
      _t(
        context,
        '新文件先写临时文件、再原子改名：不会覆盖服务上已有的同名文件',
        'A new file is written to a temporary object and then renamed atomically, so an existing file is never overwritten',
      ),
    ],
    limitations: [
      _t(
        context,
        '不支持断点续传：大文件中断后要从头重新上传',
        'No resume: an interrupted large file is uploaded again from the start',
      ),
      _t(
        context,
        '服务不支持原子改名时会拒绝写入并提示，不会降级成可能覆盖的写入',
        'If the service cannot rename atomically, Sync refuses the write and says so instead of falling back to a write that could overwrite',
      ),
      _t(
        context,
        '备份要选这个账号真正能写入的文件夹；只读入口和聚合视图都不行',
        'Backup needs a folder this account can really write to; read-only entry points and aggregated views do not work',
      ),
    ],
    credentials: _t(
      context,
      '密码存在系统安全存储里，不写进连接记录、备份或日志',
      'The password is kept in the system secure storage, never in connection records, backups or logs',
    ),
  ),
  OAuthProtocolModel(providerType: RemoteProviderType.googleDrive) =>
    ProviderCapabilitySummary(
      providerName: 'Google Drive',
      features: _oauthFeatures(context),
      limitations: [
        _t(
          context,
          '只能访问你授权给 Sync 的文件和已选择的目录',
          'Only the files granted to Sync and the folders you choose are accessible',
        ),
        _oauthResumeLimitation(context),
      ],
      credentials: _oauthCredentials(context),
    ),
  OAuthProtocolModel(providerType: RemoteProviderType.oneDrive) =>
    ProviderCapabilitySummary(
      providerName: 'OneDrive',
      features: _oauthFeatures(context),
      limitations: [
        _t(
          context,
          '目录访问受 Microsoft Graph 授权范围和账户策略限制',
          'Folder access is limited by the Microsoft Graph scopes and your account policies',
        ),
        _oauthResumeLimitation(context),
      ],
      credentials: _oauthCredentials(context),
    ),
  OAuthProtocolModel(:final providerType) => ProviderCapabilitySummary(
    providerName: providerType.name,
    features: const [],
    limitations: [
      _t(
        context,
        '这个云盘需要官方的授权组件，当前版本还不能使用',
        'This cloud drive needs an official authorization component and is not available yet',
      ),
    ],
    credentials: _t(
      context,
      '没有启用，Sync 不保存这个服务的任何凭据',
      'Not enabled, so Sync stores no credentials for this service',
    ),
  ),
};

List<String> _oauthFeatures(BuildContext? context) => [
  _t(
    context,
    '在浏览器里用 PKCE 授权，Sync 不接触你的云盘密码',
    'Authorization happens in the browser with PKCE, and Sync never sees your cloud password',
  ),
  _t(
    context,
    '浏览、上传和下载授权范围内的文件',
    'Browse, upload and download files inside the granted scope',
  ),
  _t(context, '大文件按分片上传', 'Large files are uploaded in parts'),
];

String _oauthResumeLimitation(BuildContext? context) => _t(
  context,
  '上传中断后下一次会重新开始，不会接着上次的位置继续',
  'An interrupted upload starts over next time instead of continuing where it stopped',
);

String _oauthCredentials(BuildContext? context) => _t(
  context,
  '访问令牌存在系统安全存储里，可以随时在云盘里撤销授权',
  'Access tokens are kept in the system secure storage, and you can revoke access in your cloud account at any time',
);

String _t(BuildContext? context, String zh, String en) =>
    context == null ? zh : syncText(context, zh, en);
