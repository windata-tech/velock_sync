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
  OAuthProtocolModel(
    providerType: RemoteProviderType.googleDrive,
    :final fullDriveAccess,
  ) =>
    ProviderCapabilitySummary(
      providerName: 'Google Drive',
      features: _oauthFeatures(context),
      limitations: [
        if (fullDriveAccess) ...[
          _t(
            context,
            '这个连接可以访问 Google Drive 里的全部文件，用于同步你选的普通文件夹',
            'This connection can reach all of your Google Drive files, to sync the ordinary folder you chose',
          ),
          _t(
            context,
            '同一个文件夹里有同名的文件或文件夹时会停止同步；Google 文档、表格和快捷方式不会被同步',
            'Sync stops when one folder holds several items with the same name; Google Docs, Sheets and shortcuts are not synced',
          ),
        ] else
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
  OAuthProtocolModel(providerType: RemoteProviderType.baiduNetdisk) =>
    ProviderCapabilitySummary(
      providerName: _t(context, '百度网盘', 'Baidu Netdisk'),
      features: [
        _t(
          context,
          '在百度的登录页授权，Sync 不接触你的百度密码',
          'You sign in on Baidu’s own page, and Sync never sees your Baidu password',
        ),
        _t(
          context,
          '浏览、上传和下载授权范围内的文件',
          'Browse, upload and download files inside the granted scope',
        ),
        _t(context, '大文件按分片上传', 'Large files are uploaded in parts'),
      ],
      limitations: [
        _t(
          context,
          '百度通常只允许第三方应用写入“我的应用数据”里的专属文件夹',
          'Baidu usually only lets third-party apps write to their own folder under “My app data”',
        ),
        _oauthResumeLimitation(context),
      ],
      credentials: _oauthCredentials(context),
    ),
  OAuthProtocolModel(providerType: RemoteProviderType.aliyunDrive) =>
    ProviderCapabilitySummary(
      providerName: _t(context, '阿里云盘', 'Aliyun Drive'),
      features: _oauthFeatures(context),
      limitations: [
        _t(
          context,
          '阿里云盘允许同名文件并存；Sync 创建前会先检查，不会覆盖已有文件',
          'Aliyun Drive allows files with the same name; Sync checks first and never overwrites an existing file',
        ),
        _oauthResumeLimitation(context),
      ],
      credentials: _oauthCredentials(context),
    ),
  OAuthProtocolModel(:final providerType) => throw ArgumentError.value(
    providerType,
    'providerType',
    'is not an OAuth provider',
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
