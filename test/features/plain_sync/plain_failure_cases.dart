/// The plain-domain failure copy table, shared by the widget/unit assertions in
/// `plain_failure_message_test.dart` and the locale sweep in
/// `test/l10n/plain_failure_locale_test.dart`.
///
/// Every code listed here is a literal the plain engine, the shared runner or a
/// provider can actually persist:
///
/// * `plain_folder.*` — `lib/dataset_adapters/plain_folder/plain_folder_sync_service.dart`
/// * `provider.http.*` — `lib/providers/provider_request_exception.dart`
/// * `provider.webdav.*` — `lib/providers/webdav/webdav_object_store.dart`
/// * `provider.oauth.*` — `lib/providers/oauth/*`
/// * `sync.run_busy`, `sync.unexpected` — the upload engine and the classifier
/// * `sync.interrupted` — runs the system killed before they could finish
/// * `network.offline`, `network.timeout` — transport failures the classifier
///   names instead of collapsing them into `sync.unexpected`
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/features/plain_sync/model/plain_location_presentation.dart';

/// One code to render, plus the connection name the caller would know.
typedef FailureProbe = ({String? code, String? connectionName});

/// Renders [plainFailureMessage] for every probe inside a freshly mounted tree.
///
/// A `BuildContext` is only valid for the tree it came from: re-pumping with a
/// different locale or platform reuses the same element, so a context kept from
/// an earlier mount silently resolves the *new* locale. Each call therefore
/// mounts its own keyed tree and returns plain strings.
Future<List<String>> renderPlainFailures(
  WidgetTester tester,
  Locale locale,
  List<FailureProbe> probes, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  late List<String> rendered;
  await tester.pumpWidget(
    MaterialApp(
      // A fresh key per locale/platform: without it the reused element keeps the
      // previous Localizations and animates the previous theme.
      key: ValueKey('plain-failure-${locale.languageCode}-${platform.name}'),
      locale: locale,
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(platform: platform),
      home: Builder(
        builder: (context) {
          rendered = [
            for (final probe in probes)
              plainFailureMessage(
                context,
                probe.code,
                connectionName: probe.connectionName,
              ),
          ];
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rendered;
}

/// Shorthand for a single code.
Future<String> renderPlainFailure(
  WidgetTester tester,
  Locale locale,
  String? code, {
  String? connectionName,
  TargetPlatform platform = TargetPlatform.android,
}) async => (await renderPlainFailures(tester, locale, [
  (code: code, connectionName: connectionName),
], platform: platform)).single;

/// One code and the exact sentence a user must read for it.
class FailureCopy {
  const FailureCopy(
    this.code, {
    required this.zh,
    required this.en,
    this.connectionName,
  });

  final String code;
  final String zh;
  final String en;

  /// Known by the location card, which is why the sign-in sentence can name it.
  final String? connectionName;
}

const plainFailureCases = <FailureCopy>[
  // ---- the plain folder engine ----
  FailureCopy(
    'plain_folder.local_access_lost',
    zh: '本机文件夹的访问权限已失效。请打开“详情”，重新选择本机文件夹。',
    en: 'Access to the local folder was lost. Open Details and choose the local folder again.',
  ),
  FailureCopy(
    'plain_folder.connection_missing',
    zh: '这个同步位置使用的远端连接已被删除。请打开“详情”，重新选择远端文件夹。',
    en: 'The remote connection this location used was deleted. Open Details and choose the remote folder again.',
  ),
  FailureCopy(
    'plain_folder.remote_unsupported',
    zh: '这个远端不支持文件夹同步。请改用 WebDAV 连接，例如 NAS。',
    en: 'This remote does not support folder sync. Use a WebDAV connection, for example a NAS.',
  ),
  FailureCopy(
    'plain_folder.remote_too_large',
    zh: '远端文件夹里的内容太多，本次没有同步任何文件。请选择一个更具体的远端文件夹。',
    en: 'The remote folder holds too many items, so nothing was synced. Choose a more specific remote folder.',
  ),
  FailureCopy(
    'plain_folder.remote_folder_unwritable',
    zh: '远端文件夹不存在，或这个账号不能写入。请打开“详情”，重新选择一个真实存在、可写入的远端文件夹。',
    en: 'The remote folder is missing, or this account cannot write to it. Open Details and choose a remote folder that exists and accepts writes.',
  ),
  FailureCopy(
    'plain_folder.probe_unreadable',
    zh: '远端文件夹可以连接，但写进去的测试文件读不回来。请检查这个账号的权限，或换一个有写入权限的文件夹。',
    en: 'The remote folder accepts a connection, but the test file could not be read back. Check this account’s permissions or pick a folder that may be written to.',
  ),
  FailureCopy(
    'plain_folder.profile_paused',
    zh: '这个同步位置已暂停。请先点“继续”，再开始同步。',
    en: 'This location is paused. Tap Resume, then start the sync.',
  ),
  FailureCopy(
    'plain_folder.profile_missing',
    zh: '这个同步位置已被删除，无法继续同步。请返回列表重新添加同步位置。',
    en: 'This location was deleted and cannot sync any more. Go back to the list and add the location again.',
  ),
  FailureCopy(
    'profile_removed',
    zh: '这个同步位置已被删除，无法继续同步。请返回列表重新添加同步位置。',
    en: 'This location was deleted and cannot sync any more. Go back to the list and add the location again.',
  ),
  // ---- the shared runner and infrastructure ----
  FailureCopy(
    'sync.run_busy',
    zh: '这个同步位置正在同步中，请等这次同步结束后再试。',
    en: 'This location is already syncing. Wait for that run to finish, then try again.',
  ),
  FailureCopy(
    'sync.interrupted',
    zh: '上次同步被系统中断，请重新同步。',
    en: 'The last sync was interrupted by the system. Start it again.',
  ),
  FailureCopy(
    'remote.operation_cancelled',
    zh: '这次同步被取消了，没有全部完成。需要时请重新同步。',
    en: 'This sync was cancelled before it finished. Start it again when you are ready.',
  ),
  FailureCopy(
    'staging.insufficient_space',
    zh: '本机剩余空间不足，本次同步没有完成。请清理本机空间后重试。',
    en: 'This device is out of free space, so the sync did not finish. Free up space on this device and try again.',
  ),
  FailureCopy(
    'staging.maintenance_busy',
    zh: '本机存储正在被另一个同步任务使用，请稍后重试。',
    en: 'Another sync task is using local storage right now. Try again in a moment.',
  ),
  FailureCopy(
    'staging.disk_preflight',
    zh: '本机存储暂时不可用，本次同步没有完成。请稍后重试。',
    en: 'Local storage is not available right now, so the sync did not finish. Try again in a moment.',
  ),
  FailureCopy(
    'integrity.batch_digest_mismatch',
    zh: '远端内容没有通过校验，这些改动没有应用。请检查远端文件夹是否被其他程序改动过。',
    en: 'The remote content failed verification, so those changes were not applied. Check whether another program changed the remote folder.',
  ),
  FailureCopy(
    'dataset.access.needsAuthorization',
    zh: '这个同步位置的数据源需要重新授权。请打开“详情”，重新选择本机文件夹。',
    en: 'The data source for this location needs authorization again. Open Details and choose the local folder again.',
  ),
  FailureCopy(
    'remote.object_not_found',
    zh: '远端返回了预期外的结果，本次同步没有完成。请重试；一直失败就检查远端文件夹。',
    en: 'The remote returned an unexpected result, so the sync did not finish. Try again; if it keeps failing, check the remote folder.',
  ),
  // ---- provider capabilities ----
  FailureCopy(
    'provider.webdav.atomic_create_unsupported',
    zh: '远端服务不支持安全写入，无法确认文件是不是新建的，已停止以免覆盖已有文件。请换一个支持 WebDAV 完整写入的目录或服务。',
    en: 'The remote service does not support safe writes, so it cannot prove a file is new. The sync stopped instead of overwriting. Use a folder or service with full WebDAV write support.',
  ),
  FailureCopy(
    'provider.webdav.collection_not_writable',
    zh: '远端位置无法创建文件夹。请打开“详情”，换一个真实存在、且这个账号有权限写入的远端文件夹。',
    en: 'The remote location cannot create folders. Open Details and choose a real remote folder that this account may write to.',
  ),
  FailureCopy(
    'provider.webdav.create_outcome_unknown',
    zh: '无法确认远端文件夹有没有创建成功，本次同步没有完成。请刷新远端目录确认后再试。',
    en: 'It is unclear whether the remote folder was created, so the sync did not finish. Refresh the remote folder to check, then try again.',
  ),
  FailureCopy(
    'provider.webdav.request_failed',
    zh: '远端服务拒绝了这次操作，本次同步没有完成。请检查远端地址和文件夹设置后重试。',
    en: 'The remote service refused this operation, so the sync did not finish. Check the remote address and folder settings, then try again.',
  ),
  FailureCopy(
    'provider.webdav.atomic_probe_timeout',
    zh: '连接远端超时，本次同步没有完成。请检查网络和远端服务后重试。',
    en: 'The connection to the remote timed out, so the sync did not finish. Check the network and the remote service, then try again.',
  ),
  FailureCopy(
    'provider.oauth.token_broker_required',
    zh: '云盘连接的授权不完整，文件夹同步也不支持云盘连接。请改用 WebDAV 连接，例如 NAS。',
    en: 'This cloud connection is missing its authorization, and folder sync does not support cloud drives. Use a WebDAV connection, for example a NAS.',
  ),
  FailureCopy(
    'provider.oauth.client_id_missing',
    zh: '云盘连接的授权不完整，文件夹同步也不支持云盘连接。请改用 WebDAV 连接，例如 NAS。',
    en: 'This cloud connection is missing its authorization, and folder sync does not support cloud drives. Use a WebDAV connection, for example a NAS.',
  ),
  // ---- HTTP status from any provider ----
  FailureCopy(
    'provider.http.401',
    connectionName: 'NAS-STORE',
    zh: '远端连接“NAS-STORE”没有通过认证，用户名或密码不对。请打开这个连接，重新填写用户名和密码后重试。',
    en: 'The remote connection “NAS-STORE” rejected the sign-in: the username or password is wrong. Open that connection, enter the username and password again, then retry.',
  ),
  FailureCopy(
    'provider.http.403',
    zh: '这个账号没有远端文件夹的读写权限。请换一个这个账号能写入的远端文件夹，或改用有权限的账号。',
    en: 'This account cannot read or write the remote folder. Choose a folder this account may write to, or use an account that has access.',
  ),
  FailureCopy(
    'provider.http.404',
    zh: '远端文件夹不存在，可能已被移动或删除。请打开“详情”，重新选择远端文件夹。',
    en: 'The remote folder does not exist; it may have been moved or deleted. Open Details and choose the remote folder again.',
  ),
  FailureCopy(
    'provider.http.409',
    zh: '远端内容已被其他设备或程序改动，本次同步没有完成。请稍后重试。',
    en: 'Another device or program changed the remote content, so the sync did not finish. Try again in a moment.',
  ),
  FailureCopy(
    'provider.http.412',
    zh: '远端内容已被其他设备或程序改动，本次同步没有完成。请稍后重试。',
    en: 'Another device or program changed the remote content, so the sync did not finish. Try again in a moment.',
  ),
  FailureCopy(
    'provider.http.429',
    zh: '远端服务暂时不接受更多请求，本次同步没有完成。请等几分钟再重试。',
    en: 'The remote service is not accepting more requests right now, so the sync did not finish. Wait a few minutes and try again.',
  ),
  FailureCopy(
    'provider.http.507',
    zh: '云端空间不足，本次同步没有完成。请先清理远端文件或扩容，再重新同步。',
    en: 'The cloud drive is out of space, so the sync did not finish. Free up space or add more, then sync again.',
  ),
  FailureCopy(
    'provider.http.503',
    zh: '远端服务出错了，本次同步没有完成。请稍后重试；一直失败就检查远端服务是否正常。',
    en: 'The remote service returned an error, so the sync did not finish. Try again later; if it keeps failing, check that the service is healthy.',
  ),
  FailureCopy(
    'provider.http.400',
    zh: '远端服务拒绝了这次操作，本次同步没有完成。请检查远端文件夹设置后重试。',
    en: 'The remote service refused this operation, so the sync did not finish. Check the remote folder settings and try again.',
  ),
  // ---- transport ----
  FailureCopy(
    'network.offline',
    zh: '没有网络连接，连上网络后再试。',
    en: 'There is no network connection. Connect to the internet and try again.',
  ),
  FailureCopy(
    'network.timeout',
    zh: '连接远端超时，本次同步没有完成。请检查网络和远端服务后重试。',
    en: 'The connection to the remote timed out, so the sync did not finish. Check the network and the remote service, then try again.',
  ),
  FailureCopy(
    'network.certificate',
    zh: '无法验证远端服务器的身份，证书有问题。请检查服务器地址和证书，或联系服务管理员。',
    en: 'The remote server could not be verified because of a certificate problem. Check the server address and its certificate, or ask the service administrator.',
  ),
  FailureCopy(
    'network.unreachable',
    zh: '这次同步没能连上远端，没有完成。请检查网络和远端服务后重试。',
    en: 'The sync could not reach the remote and did not finish. Check the network and the remote service, then try again.',
  ),
];

/// The sentence for a code nobody has mapped yet: it must still say what to do
/// next, and it must never echo the code.
const unknownPlainFailureZh = '同步没有完成，原因还不明确。请先重试一次；一直失败就打开“详情”检查本机文件夹和远端文件夹。';
const unknownPlainFailureEn =
    'The sync did not finish and the cause is not clear. Try again first; if it keeps failing, open Details and check the local and remote folders.';
