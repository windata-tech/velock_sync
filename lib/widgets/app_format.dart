import 'package:velock_sync/l10n/sync_locale.dart';
import 'package:flutter/cupertino.dart';

/// Shared, presentation-only formatters.
///
/// Every user-facing date, size and error string goes through this file so the
/// app never mixes `2026-09-12 09:02`, `50.0 MB` and raw protocol codes in the
/// same list.
abstract final class AppFormat {
  /// `刚刚` / `x 分钟前` / `今天 HH:mm` / `昨天 HH:mm` / `M月d日 HH:mm`.
  static String relativeTime(
    DateTime? value, {
    DateTime? now,
    BuildContext? context,
  }) {
    if (value == null) return '—';
    final local = value.toLocal();
    final reference = (now ?? DateTime.now()).toLocal();
    final difference = reference.difference(local);

    if (difference.isNegative) return _time(local);
    if (difference.inMinutes < 1) {
      return _optionalSyncText(context, '刚刚', "Just now");
    }
    if (difference.inMinutes < 60) {
      return _optionalSyncText(
        context,
        '${difference.inMinutes} 分钟前',
        "${difference.inMinutes} min ago",
      );
    }

    final today = DateTime(reference.year, reference.month, reference.day);
    final day = DateTime(local.year, local.month, local.day);
    final dayDelta = today.difference(day).inDays;
    if (dayDelta == 0) {
      return _optionalSyncText(
        context,
        '今天 ${_time(local)}',
        "Today ${_time(local)}",
      );
    }
    if (dayDelta == 1) {
      return _optionalSyncText(
        context,
        '昨天 ${_time(local)}',
        "Yesterday ${_time(local)}",
      );
    }
    if (local.year == reference.year) {
      return _optionalSyncText(
        context,
        '${local.month}月${local.day}日 ${_time(local)}',
        "${local.month}/${local.day} ${_time(local)}",
      );
    }
    return _optionalSyncText(
      context,
      '${local.year}年${local.month}月${local.day}日',
      "${local.year}-${_pad(local.month)}-${_pad(local.day)}",
    );
  }

  /// Absolute stamp for detail sheets where precision matters.
  static String stamp(DateTime? value) {
    if (value == null) return '—';
    final local = value.toLocal();
    return '${local.year}-${_pad(local.month)}-${_pad(local.day)} '
        '${_time(local)}';
  }

  /// `0 B` / `512 KB` / `1.5 MB` / `2 GB` (1024-based, no trailing `.0`).
  static String bytes(num? value) {
    if (value == null) return '—';
    final bytes = value.toDouble();
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final decimals = unit == 0
        ? 0
        : (size >= 10 || size.truncateToDouble() == size ? 0 : 1);
    return '${size.toStringAsFixed(decimals)} ${units[unit]}';
  }

  /// Turning an internal error code into the sentence a user can act on.
  ///
  /// The code itself stays available through [technicalDetail] so support and
  /// logs keep their precision without leaking into the primary copy.
  static String errorSummary(
    String? code, {
    String? fallback,
    BuildContext? context,
  }) {
    final normalized = code?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) {
      return fallback ??
          _optionalSyncText(
            context,
            '同步未完成，请稍后重试。',
            "Sync did not complete. Please try again later.",
          );
    }
    if (normalized == 'provider.webdav.atomic_create_unsupported') {
      return _optionalSyncText(
        context,
        '这个云端位置不能安全保存备份，已停止传输以保护已有数据。请检查云端服务设置或联系服务提供方。',
        'This cloud location cannot safely save backups. Transfers stopped to protect existing data. Check storage settings or contact the provider.',
      );
    }
    if (normalized == 'provider.webdav.collection_not_writable') {
      return _optionalSyncText(
        context,
        '当前选中的位置不能新建备份文件夹。请打开共享文件夹，选择一个有写入权限的实际文件夹，不要只选 NAS 入口。',
        'The selected location cannot create a backup folder. Open the shared folder and choose an actual folder with write access; do not select only the NAS entry point.',
      );
    }
    if (normalized == 'remote.velock_history_incomplete') {
      return _optionalSyncText(
        context,
        '远端缺少历史备份，同步未完成。请连接原来的完整备份目录；不要删除旧备份或重置同步数据。',
        'Remote backup history is incomplete. Reconnect the original complete backup folder. Do not delete the old backup or reset sync data.',
      );
    }
    if (normalized.contains('401') || normalized.contains('unauthor')) {
      return _optionalSyncText(
        context,
        '远端拒绝了访问，请重新授权后再试。',
        "Remote access was denied. Authorize access again and retry.",
      );
    }
    if (normalized.contains('403') || normalized.contains('forbidden')) {
      return _optionalSyncText(
        context,
        '远端账号没有该目录的读写权限。',
        "The remote account does not have read/write access to this folder.",
      );
    }
    if (normalized.contains('404') || normalized.contains('not_found')) {
      return _optionalSyncText(
        context,
        '远端目录不存在，请检查路径配置。',
        "The remote folder does not exist. Check the configured path.",
      );
    }
    if (normalized.contains('409') || normalized.contains('conflict')) {
      return _optionalSyncText(
        context,
        '远端数据已被其他设备修改。',
        "Remote data was changed by another device.",
      );
    }
    if (normalized.contains('timeout') || normalized.contains('timedout')) {
      return _optionalSyncText(
        context,
        '连接超时，请检查网络后重试。',
        "Connection timed out. Check the network and retry.",
      );
    }
    if (normalized.contains('network') ||
        normalized.contains('socket') ||
        normalized.contains('dns') ||
        normalized.contains('unreachable')) {
      return _optionalSyncText(
        context,
        '无法连接远端，请检查网络与服务器地址。',
        "Could not connect. Check the network and server address.",
      );
    }
    if (normalized.contains('token_broker') || normalized.contains('oauth')) {
      return _optionalSyncText(
        context,
        '还没有完成授权配置，请先填写客户端信息。',
        "Authorization setup is incomplete. Enter the client information first.",
      );
    }
    if (normalized.contains('run_busy')) {
      return _optionalSyncText(
        context,
        '这个同步配置正在运行。',
        "This sync profile is already running.",
      );
    }
    if (normalized.contains('expired')) {
      return _optionalSyncText(
        context,
        '授权已过期，请重新授权。',
        "Authorization expired. Authorize access again.",
      );
    }
    if (normalized.contains('untrusted') || normalized.contains('receipt')) {
      return _optionalSyncText(
        context,
        '返回值未通过校验，本次改动未应用。',
        "The response failed validation. No changes were applied.",
      );
    }
    if (normalized.contains('pending')) {
      return _optionalSyncText(
        context,
        '需要回到格间完成处理。',
        "Return to Velock to complete this action.",
      );
    }
    if (normalized.startsWith('velock-')) {
      return _optionalSyncText(
        context,
        '需要打开格间接管这次操作。',
        "Open Velock to handle this action.",
      );
    }
    if (normalized.contains('unexpected') || normalized.contains('unknown')) {
      return _optionalSyncText(
        context,
        '同步未完成，请检查同步配置后重试。',
        "Sync did not complete. Check the sync profile and retry.",
      );
    }
    return fallback ??
        _optionalSyncText(
          context,
          '同步未完成，请稍后重试。',
          "Sync did not complete. Please try again later.",
        );
  }

  /// Raw, copyable detail for the collapsed “技术详情” panel.
  static String technicalDetail({
    BuildContext? context,
    String? code,
    String? profileId,
    DateTime? at,
    String? extra,
  }) {
    final lines = <String>[
      if (code != null && code.trim().isNotEmpty)
        _optionalSyncText(
          context,
          '错误代码：${code.trim()}',
          "Error code: ${code.trim()}",
        ),
      if (profileId != null && profileId.isNotEmpty)
        _optionalSyncText(context, '配置标识：$profileId', "Profile ID: $profileId"),
      if (at != null)
        _optionalSyncText(
          context,
          '记录时间：${stamp(at)}',
          "Recorded at: ${stamp(at)}",
        ),
      if (extra != null && extra.trim().isNotEmpty) extra.trim(),
    ];
    return lines.join('\n');
  }

  static String _time(DateTime value) =>
      '${_pad(value.hour)}:${_pad(value.minute)}';

  static String _pad(int value) => value.toString().padLeft(2, '0');
}

/// Small helpers used by the new component layer.
extension AppFormatContext on BuildContext {
  String relativeTime(DateTime? value) => AppFormat.relativeTime(value);
  String bytesLabel(num? value) => AppFormat.bytes(value);
}

// Omitted context preserves the legacy Chinese-only formatter API.
String _optionalSyncText(BuildContext? context, String zh, String en) =>
    context == null ? zh : syncText(context, zh, en);
