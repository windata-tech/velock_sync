import 'package:flutter/widgets.dart';
import 'package:velock_sync/appearance/design_tokens.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/mirror_models.dart';
import 'package:velock_sync/dataset_adapters/plain_folder/plain_folder_sync_profile.dart';
import 'package:velock_sync/features/plain_sync/state/plain_sync_providers.dart';
import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:velock_sync/widgets/app_format.dart';

/// User-facing wording for the mirror direction. The deletion semantics are
/// spelled out because they differ per direction.
String directionLabel(BuildContext context, MirrorDirection direction) =>
    switch (direction) {
      MirrorDirection.bidirectional => syncText(context, '双向同步', 'Two-way'),
      MirrorDirection.uploadOnly => syncText(context, '仅上传', 'Upload only'),
      MirrorDirection.downloadOnly => syncText(context, '仅下载', 'Download only'),
    };

String directionExplanation(
  BuildContext context,
  MirrorDirection direction,
) => switch (direction) {
  MirrorDirection.bidirectional => syncText(
    context,
    '两边改动互相同步；同一个文件两边都改过时按冲突处理方式保留。本机删除会同步删除远端文件。',
    'Changes flow both ways. If the same file changed on both sides, the conflict setting decides. Deleting a file here also deletes it remotely.',
  ),
  MirrorDirection.uploadOnly => syncText(
    context,
    '只把本机的内容推到远端，远端独有的文件不会被下载或删除。本机删除会同步删除远端文件。',
    'Only this device writes to the remote folder. Files that exist only remotely are neither downloaded nor deleted. Deleting a file here deletes it remotely.',
  ),
  MirrorDirection.downloadOnly => syncText(
    context,
    '只把远端内容取回本机，本机对已同步文件的修改会被远端版本覆盖；本机独有的新文件不会被删除。',
    'Only the remote folder writes here. Local edits to already-synced files are overwritten by the remote version; files that exist only here are never deleted.',
  ),
};

String conflictPolicyLabel(BuildContext context, MirrorConflictPolicy policy) =>
    switch (policy) {
      MirrorConflictPolicy.keepBoth => syncText(
        context,
        '保留两份（推荐）',
        'Keep both (recommended)',
      ),
      MirrorConflictPolicy.preferLocal => syncText(
        context,
        '以本机为准',
        'Prefer this device',
      ),
      MirrorConflictPolicy.preferRemote => syncText(
        context,
        '以远端为准',
        'Prefer the remote folder',
      ),
    };

String conflictPolicyExplanation(
  BuildContext context,
  MirrorConflictPolicy policy,
) => switch (policy) {
  MirrorConflictPolicy.keepBoth => syncText(
    context,
    '远端版本保留原名，本机版本另存为“文件名 (本机冲突 日期 时间).扩展名”，两份都不会丢。',
    'The remote version keeps the original name and the local version is saved as “name (local conflict date time).ext”. Nothing is lost.',
  ),
  MirrorConflictPolicy.preferLocal => syncText(
    context,
    '冲突时用本机版本覆盖远端文件。',
    'On a conflict, the local version overwrites the remote file.',
  ),
  MirrorConflictPolicy.preferRemote => syncText(
    context,
    '冲突时用远端版本覆盖本机文件。',
    'On a conflict, the remote version overwrites the local file.',
  ),
};

String initialSyncPolicyLabel(
  BuildContext context,
  MirrorInitialSyncPolicy policy,
) => switch (policy) {
  MirrorInitialSyncPolicy.merge => syncText(
    context,
    '合并两边（推荐）',
    'Merge both sides (recommended)',
  ),
  MirrorInitialSyncPolicy.localWins => syncText(
    context,
    '以本机覆盖远端',
    'This device wins',
  ),
  MirrorInitialSyncPolicy.remoteWins => syncText(
    context,
    '以远端覆盖本机',
    'The remote folder wins',
  ),
};

/// Status line for one location card.
class PlainLocationStatus {
  const PlainLocationStatus({
    required this.label,
    required this.tone,
    this.detail,
    this.actionLabel,
  });

  final String label;
  final AppTone tone;
  final String? detail;
  final String? actionLabel;
}

PlainLocationStatus plainLocationStatus(
  BuildContext context,
  PlainLocationView view,
) {
  final stats = view.stats;
  if (view.profile.state == PlainFolderProfileState.paused) {
    return PlainLocationStatus(
      label: syncText(context, '已暂停', 'Paused'),
      tone: AppTone.neutral,
      detail: syncText(
        context,
        '不会自动同步；点“继续”后恢复。',
        'Nothing syncs while paused. Resume to continue.',
      ),
      actionLabel: syncText(context, '继续', 'Resume'),
    );
  }
  if (view.isRunning) {
    return PlainLocationStatus(
      label: syncText(context, '正在同步', 'Syncing'),
      tone: AppTone.brand,
      detail: syncText(context, '正在传输，请稍候。', 'Transferring, please wait.'),
    );
  }
  if (view.didFail) {
    return PlainLocationStatus(
      label: syncText(context, '上次同步失败', 'Last sync failed'),
      tone: AppTone.danger,
      detail: plainFailureMessage(
        context,
        view.latestRunFailureCode,
        connectionName: view.connection?.name,
      ),
      actionLabel: syncText(context, '重试', 'Try again'),
    );
  }
  if (view.hasHeldDeletions) {
    final count = stats?.heldDeletionCount ?? 0;
    return PlainLocationStatus(
      label: syncText(context, '有删除等待确认', 'Deletions need confirmation'),
      tone: AppTone.attention,
      detail: syncText(
        context,
        '检测到 $count 项删除，超过安全阈值，已暂停删除。确认后才会执行。',
        '$count deletions exceeded the safety threshold and were held back. Confirm to apply them.',
      ),
      actionLabel: syncText(context, '查看并确认', 'Review and confirm'),
    );
  }
  if (!view.hasSyncedBefore) {
    return PlainLocationStatus(
      label: syncText(context, '还没有同步过', 'Not synced yet'),
      tone: AppTone.neutral,
      detail: syncText(
        context,
        '点“立即同步”开始第一次同步。',
        'Start the first sync when you are ready.',
      ),
      actionLabel: syncText(context, '立即同步', 'Sync now'),
    );
  }
  final changed = stats?.changedCount ?? 0;
  return PlainLocationStatus(
    label: changed == 0
        ? syncText(context, '已是最新', 'Up to date')
        : syncText(context, '同步完成', 'Sync finished'),
    tone: AppTone.ok,
    actionLabel: syncText(context, '立即同步', 'Sync now'),
  );
}

/// "上传 3 · 下载 1 · 删除 2 · 冲突 1 · 12:30" — never a vague "backed up".
String plainRunSummary(BuildContext context, MirrorRunStats? stats) {
  if (stats == null || stats.finishedAt == null) {
    return syncText(context, '还没有同步记录。', 'No sync has run yet.');
  }
  if (stats.didFail) {
    return plainFailureMessage(context, stats.failureCode);
  }
  final parts = <String>[
    syncText(
      context,
      '上传 ${stats.uploadedFileCount}',
      'up ${stats.uploadedFileCount}',
    ),
    syncText(
      context,
      '下载 ${stats.downloadedFileCount}',
      'down ${stats.downloadedFileCount}',
    ),
    if (stats.deletedLocalCount + stats.deletedRemoteCount > 0)
      syncText(
        context,
        '删除 ${stats.deletedLocalCount + stats.deletedRemoteCount}',
        'deleted ${stats.deletedLocalCount + stats.deletedRemoteCount}',
      ),
    AppFormat.stamp(stats.finishedAt!),
  ];
  return parts.join(' · ');
}

/// The one sentence a plain-sync user reads when a run fails.
///
/// Every code the folder engine, the shared runner and the providers can
/// persist is mapped here, so the location card, the detail page and the run
/// dialog can never disagree, and a wrong password, an offline device, a full
/// disk and a location that is merely busy stop sharing one sentence. The raw
/// code is never part of this copy — it belongs in the diagnostics, not in the
/// paragraph a user has to read.
///
/// [connectionName] is optional: the authentication sentence names the
/// connection that has to be fixed whenever the caller knows its name.
String plainFailureMessage(
  BuildContext context,
  String? errorCode, {
  String? connectionName,
}) {
  final code = errorCode?.trim().toLowerCase() ?? '';

  // Exact codes first: each one has its own next action.
  final known = switch (code) {
    // The plain folder engine.
    'plain_folder.local_access_lost' =>
      isApplePlatform(context)
          ? syncText(
              context,
              '本机文件夹的访问权限已失效，在 iPhone 或 iPad 上重装 App 后就是这样。请打开“详情”，重新选择本机文件夹。',
              'Access to the local folder was lost — this is what happens after reinstalling the app on iPhone or iPad. Open Details and choose the local folder again.',
            )
          : syncText(
              context,
              '本机文件夹的访问权限已失效。请打开“详情”，重新选择本机文件夹。',
              'Access to the local folder was lost. Open Details and choose the local folder again.',
            ),
    'plain_folder.connection_missing' => syncText(
      context,
      '这个同步位置使用的远端连接已被删除。请打开“详情”，重新选择远端文件夹。',
      'The remote connection this location used was deleted. Open Details and choose the remote folder again.',
    ),
    'plain_folder.remote_unsupported' => syncText(
      context,
      '这个连接不能用于文件夹同步。请改用 WebDAV（例如 NAS）、OneDrive、百度网盘或阿里云盘；Google Drive 需要在添加同步位置时新建一个允许访问全部文件的连接。',
      'This connection cannot be used for folder sync. Use WebDAV (for example a NAS), OneDrive, Baidu Netdisk or Aliyun Drive; for Google Drive, add a new connection with access to all files while adding the sync location.',
    ),
    'provider.baidu.unsupported_name' => syncText(
      context,
      '有文件名里含有百度网盘不允许的字符（\\ ? | " < > : *）。请在本机改名后再同步。',
      'A file name contains characters Baidu Netdisk does not allow (\\ ? | " < > : *). Rename it on this device, then sync again.',
    ),
    'provider.onedrive.unsupported_name' => syncText(
      context,
      '有文件名里含有 OneDrive 不允许的字符（" * : < > ? \\ |）。请在本机改名后再同步。',
      'A file name contains characters OneDrive does not allow (" * : < > ? \\ |). Rename it on this device, then sync again.',
    ),
    'provider.aliyun.unsupported_name' => syncText(
      context,
      '有文件名阿里云盘不能保存。请在本机改名后再同步。',
      'A file name cannot be stored on Aliyun Drive. Rename it on this device, then sync again.',
    ),
    'provider.google.duplicate_name' => syncText(
      context,
      'Google Drive 的同一个文件夹里有同名的文件、文件夹或 Google 文档，Sync 分不清该用哪一个，这次没有继续同步。请在 Google Drive 里把多余的改名或删除后再同步。',
      'One Google Drive folder holds several files, folders or Google Docs with the same name, so Sync cannot tell which one is meant and stopped. Rename or remove the extra ones in Google Drive, then sync again.',
    ),
    'plain_folder.remote_too_large' => syncText(
      context,
      '远端文件夹里的内容太多，本次没有同步任何文件。请选择一个更具体的远端文件夹。',
      'The remote folder holds too many items, so nothing was synced. Choose a more specific remote folder.',
    ),
    'plain_folder.remote_folder_unwritable' => syncText(
      context,
      '远端文件夹不存在，或这个账号不能写入。请打开“详情”，重新选择一个真实存在、可写入的远端文件夹。',
      'The remote folder is missing, or this account cannot write to it. Open Details and choose a remote folder that exists and accepts writes.',
    ),
    'plain_folder.probe_unreadable' => syncText(
      context,
      '远端文件夹可以连接，但写进去的测试文件读不回来。请检查这个账号的权限，或换一个有写入权限的文件夹。',
      'The remote folder accepts a connection, but the test file could not be read back. Check this account’s permissions or pick a folder that may be written to.',
    ),
    'provider.saf.replace_failed' => syncText(
      context,
      '这个文件没能替换成功，本机上的旧文件仍然保留着原名字。请重试一次；一直失败就把这个同步位置换到另一个本机文件夹。',
      'That file could not be replaced, and the previous file on this device still has its own name. Try again; if it keeps failing, point this location at another local folder.',
    ),
    'plain_folder.remote_folder_missing' => syncText(
      context,
      '远端找不到这个文件夹了：可能被改名、移走，或者那个硬盘/共享没有挂上。这次没有删除本机文件。请到远端确认文件夹还在，再重新同步。',
      'The remote folder cannot be found: it may have been renamed, moved, or its drive or share is not mounted. Nothing was deleted on this device. Check the remote folder and sync again.',
    ),
    'plain_folder.upload_incomplete' => syncText(
      context,
      '有文件没有完整上传，本次同步已停止，也没有把不完整的文件记成已同步。请重试一次；一直失败就换一个网络环境。',
      'A file did not upload completely, so this sync stopped and the incomplete copy was not recorded as synced. Try again; if it keeps failing, use a different network.',
    ),
    'plain_folder.remote_too_deep' => syncText(
      context,
      '远端文件夹的目录太深，这一层里面还有更深的目录没读到。这次没有删除本机文件，请把同步位置选到一个更靠里的文件夹。',
      'The remote folder is nested too deeply: folders below this level could not be read. Nothing was deleted on this device. Point the location at a folder further inside.',
    ),
    'plain_folder.profile_paused' => syncText(
      context,
      '这个同步位置已暂停。请先点“继续”，再开始同步。',
      'This location is paused. Tap Resume, then start the sync.',
    ),
    'plain_folder.profile_missing' || 'profile_removed' => syncText(
      context,
      '这个同步位置已被删除，无法继续同步。请返回列表重新添加同步位置。',
      'This location was deleted and cannot sync any more. Go back to the list and add the location again.',
    ),
    // The shared runner and infrastructure.
    'sync.run_busy' => syncText(
      context,
      '这个同步位置正在同步中，请等这次同步结束后再试。',
      'This location is already syncing. Wait for that run to finish, then try again.',
    ),
    'sync.interrupted' => syncText(
      context,
      '上次同步被系统中断，请重新同步。',
      'The last sync was interrupted by the system. Start it again.',
    ),
    'remote.operation_cancelled' => syncText(
      context,
      '这次同步被取消了，没有全部完成。需要时请重新同步。',
      'This sync was cancelled before it finished. Start it again when you are ready.',
    ),
    'staging.insufficient_space' => syncText(
      context,
      '本机剩余空间不足，本次同步没有完成。请清理本机空间后重试。',
      'This device is out of free space, so the sync did not finish. Free up space on this device and try again.',
    ),
    'staging.maintenance_busy' => syncText(
      context,
      '本机存储正在被另一个同步任务使用，请稍后重试。',
      'Another sync task is using local storage right now. Try again in a moment.',
    ),
    // Provider capabilities.
    'provider.webdav.atomic_create_unsupported' => syncText(
      context,
      '远端服务不支持安全写入，无法确认文件是不是新建的，已停止以免覆盖已有文件。请换一个支持 WebDAV 完整写入的目录或服务。',
      'The remote service does not support safe writes, so it cannot prove a file is new. The sync stopped instead of overwriting. Use a folder or service with full WebDAV write support.',
    ),
    'provider.webdav.collection_not_writable' => syncText(
      context,
      '远端位置无法创建文件夹。请打开“详情”，换一个真实存在、且这个账号有权限写入的远端文件夹。',
      'The remote location cannot create folders. Open Details and choose a real remote folder that this account may write to.',
    ),
    'provider.webdav.create_outcome_unknown' => syncText(
      context,
      '无法确认远端文件夹有没有创建成功，本次同步没有完成。请刷新远端目录确认后再试。',
      'It is unclear whether the remote folder was created, so the sync did not finish. Refresh the remote folder to check, then try again.',
    ),
    'network.unreachable' => syncText(
      context,
      '连不上远端服务器，本次同步没有完成。请检查网络、服务器地址和端口，并确认服务器正在运行。',
      'Could not reach the remote server, so the sync did not finish. Check the network, the server address and port, and that the server is running.',
    ),
    'network.certificate' => syncText(
      context,
      '无法验证远端服务器的身份，证书有问题。请检查服务器地址和证书，或联系服务管理员。',
      'The remote server could not be verified because of a certificate problem. Check the server address and its certificate, or ask the service administrator.',
    ),
    _ => null,
  };
  if (known != null) return known;

  // Families whose meaning is carried by the prefix or by an HTTP status.
  if (code.contains('timeout') ||
      code.contains('timedout') ||
      code.contains('timed_out')) {
    return syncText(
      context,
      '连接远端超时，本次同步没有完成。请检查网络和远端服务后重试。',
      'The connection to the remote timed out, so the sync did not finish. Check the network and the remote service, then try again.',
    );
  }
  if (code.contains('offline') || code.contains('no_network')) {
    return syncText(
      context,
      '没有网络连接，连上网络后再试。',
      'There is no network connection. Connect to the internet and try again.',
    );
  }
  if (code.startsWith('provider.http.')) {
    final status = int.tryParse(code.substring('provider.http.'.length)) ?? 0;
    return switch (status) {
      401 => _plainAuthenticationMessage(context, connectionName),
      403 => syncText(
        context,
        '这个账号没有远端文件夹的读写权限。请换一个这个账号能写入的远端文件夹，或改用有权限的账号。',
        'This account cannot read or write the remote folder. Choose a folder this account may write to, or use an account that has access.',
      ),
      404 => syncText(
        context,
        '远端文件夹不存在，可能已被移动或删除。请打开“详情”，重新选择远端文件夹。',
        'The remote folder does not exist; it may have been moved or deleted. Open Details and choose the remote folder again.',
      ),
      409 || 412 => syncText(
        context,
        '远端内容已被其他设备或程序改动，本次同步没有完成。请稍后重试。',
        'Another device or program changed the remote content, so the sync did not finish. Try again in a moment.',
      ),
      429 => syncText(
        context,
        '远端服务暂时不接受更多请求，本次同步没有完成。请等几分钟再重试。',
        'The remote service is not accepting more requests right now, so the sync did not finish. Wait a few minutes and try again.',
      ),
      507 => syncText(
        context,
        '云端空间不足，本次同步没有完成。请先清理远端文件或扩容，再重新同步。',
        'The cloud drive is out of space, so the sync did not finish. Free up space or add more, then sync again.',
      ),
      >= 500 && <= 599 => syncText(
        context,
        '远端服务出错了，本次同步没有完成。请稍后重试；一直失败就检查远端服务是否正常。',
        'The remote service returned an error, so the sync did not finish. Try again later; if it keeps failing, check that the service is healthy.',
      ),
      _ => syncText(
        context,
        '远端服务拒绝了这次操作，本次同步没有完成。请检查远端文件夹设置后重试。',
        'The remote service refused this operation, so the sync did not finish. Check the remote folder settings and try again.',
      ),
    };
  }
  if (code.startsWith('provider.oauth.')) {
    return syncText(
      context,
      '云盘连接的登录不完整或已失效。请在“连接”页重新登录这个网盘后再同步。',
      'This cloud drive sign-in is incomplete or has expired. Sign in to the drive again on the Connections page, then sync.',
    );
  }
  if (code.startsWith('provider.webdav.')) {
    return syncText(
      context,
      '远端服务拒绝了这次操作，本次同步没有完成。请检查远端地址和文件夹设置后重试。',
      'The remote service refused this operation, so the sync did not finish. Check the remote address and folder settings, then try again.',
    );
  }
  if (code.startsWith('network.')) {
    return syncText(
      context,
      '这次同步没能连上远端，没有完成。请检查网络和远端服务后重试。',
      'The sync could not reach the remote and did not finish. Check the network and the remote service, then try again.',
    );
  }
  if (code.startsWith('integrity.')) {
    return syncText(
      context,
      '远端内容没有通过校验，这些改动没有应用。请检查远端文件夹是否被其他程序改动过。',
      'The remote content failed verification, so those changes were not applied. Check whether another program changed the remote folder.',
    );
  }
  if (code.startsWith('dataset.access.')) {
    return syncText(
      context,
      '这个同步位置的数据源需要重新授权。请打开“详情”，重新选择本机文件夹。',
      'The data source for this location needs authorization again. Open Details and choose the local folder again.',
    );
  }
  if (code.startsWith('staging.')) {
    return syncText(
      context,
      '本机存储暂时不可用，本次同步没有完成。请稍后重试。',
      'Local storage is not available right now, so the sync did not finish. Try again in a moment.',
    );
  }
  if (code.startsWith('remote.')) {
    return syncText(
      context,
      '远端返回了预期外的结果，本次同步没有完成。请重试；一直失败就检查远端文件夹。',
      'The remote returned an unexpected result, so the sync did not finish. Try again; if it keeps failing, check the remote folder.',
    );
  }
  if (code.isEmpty) {
    return syncText(
      context,
      '同步没有完成。请重试一次；一直失败就打开“详情”检查本机文件夹和远端文件夹。',
      'The sync did not finish. Try again; if it keeps failing, open Details and check the local and remote folders.',
    );
  }
  // An unknown code is still a dead end for the user, so the sentence says what
  // to do next without ever echoing the code itself.
  return syncText(
    context,
    '同步没有完成，原因还不明确。请先重试一次；一直失败就打开“详情”检查本机文件夹和远端文件夹。',
    'The sync did not finish and the cause is not clear. Try again first; if it keeps failing, open Details and check the local and remote folders.',
  );
}

/// Sign-in failure. Names the connection when the caller knows it, because
/// "which connection?" is the first question a wrong password raises.
String _plainAuthenticationMessage(
  BuildContext context,
  String? connectionName,
) {
  final name = connectionName?.trim();
  if (name == null || name.isEmpty) {
    return syncText(
      context,
      '远端连接没有通过认证，用户名或密码不对。请打开这个连接，重新填写用户名和密码后重试。',
      'The remote connection rejected the sign-in: the username or password is wrong. Open that connection, enter the username and password again, then retry.',
    );
  }
  return syncText(
    context,
    '远端连接“$name”没有通过认证，用户名或密码不对。请打开这个连接，重新填写用户名和密码后重试。',
    'The remote connection “$name” rejected the sign-in: the username or password is wrong. Open that connection, enter the username and password again, then retry.',
  );
}
