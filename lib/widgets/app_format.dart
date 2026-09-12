import 'package:flutter/cupertino.dart';

/// Shared, presentation-only formatters.
///
/// Every user-facing date, size and error string goes through this file so the
/// app never mixes `2026-09-12 09:02`, `50.0 MiB` and raw protocol codes in the
/// same list.
abstract final class AppFormat {
  /// `刚刚` / `x 分钟前` / `今天 HH:mm` / `昨天 HH:mm` / `M月d日 HH:mm`.
  static String relativeTime(DateTime? value, {DateTime? now}) {
    if (value == null) return '—';
    final local = value.toLocal();
    final reference = (now ?? DateTime.now()).toLocal();
    final difference = reference.difference(local);

    if (difference.isNegative) return _time(local);
    if (difference.inMinutes < 1) return '刚刚';
    if (difference.inMinutes < 60) return '${difference.inMinutes} 分钟前';

    final today = DateTime(reference.year, reference.month, reference.day);
    final day = DateTime(local.year, local.month, local.day);
    final dayDelta = today.difference(day).inDays;
    if (dayDelta == 0) return '今天 ${_time(local)}';
    if (dayDelta == 1) return '昨天 ${_time(local)}';
    if (local.year == reference.year) {
      return '${local.month}月${local.day}日 ${_time(local)}';
    }
    return '${local.year}年${local.month}月${local.day}日';
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
    final decimals = unit == 0 ? 0 : (size >= 10 || size.truncateToDouble() == size ? 0 : 1);
    return '${size.toStringAsFixed(decimals)} ${units[unit]}';
  }

  /// Turning an internal error code into the sentence a user can act on.
  ///
  /// The code itself stays available through [technicalDetail] so support and
  /// logs keep their precision without leaking into the primary copy.
  static String errorSummary(String? code, {String? fallback}) {
    final normalized = code?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return fallback ?? '同步未完成，请稍后重试。';
    if (normalized.contains('401') || normalized.contains('unauthor')) {
      return '远端拒绝了访问，请重新授权后再试。';
    }
    if (normalized.contains('403') || normalized.contains('forbidden')) {
      return '远端账号没有该目录的读写权限。';
    }
    if (normalized.contains('404') || normalized.contains('not_found')) {
      return '远端目录不存在，请检查路径配置。';
    }
    if (normalized.contains('409') || normalized.contains('conflict')) {
      return '远端数据已被其他设备修改。';
    }
    if (normalized.contains('timeout') || normalized.contains('timedout')) {
      return '连接超时，请检查网络后重试。';
    }
    if (normalized.contains('network') || normalized.contains('socket') ||
        normalized.contains('dns') || normalized.contains('unreachable')) {
      return '无法连接远端，请检查网络与服务器地址。';
    }
    if (normalized.contains('token_broker') || normalized.contains('oauth')) {
      return '还没有完成授权配置，请先填写客户端信息。';
    }
    if (normalized.contains('run_busy')) {
      return '这个同步配置正在运行。';
    }
    if (normalized.contains('expired')) {
      return '授权已过期，请重新授权。';
    }
    if (normalized.contains('untrusted') || normalized.contains('receipt')) {
      return '返回值未通过校验，本次改动未应用。';
    }
    if (normalized.contains('pending')) {
      return '需要回到格间完成处理。';
    }
    if (normalized.startsWith('velock-')) {
      return '需要打开格间接管这次操作。';
    }
    if (normalized.contains('unexpected') || normalized.contains('unknown')) {
      return '同步未完成，请检查同步配置后重试。';
    }
    return fallback ?? '同步未完成，请稍后重试。';
  }

  /// Raw, copyable detail for the collapsed “技术详情” panel.
  static String technicalDetail({
    String? code,
    String? profileId,
    DateTime? at,
    String? extra,
  }) {
    final lines = <String>[
      if (code != null && code.trim().isNotEmpty) '错误代码：${code.trim()}',
      if (profileId != null && profileId.isNotEmpty) '配置标识：$profileId',
      if (at != null) '记录时间：${stamp(at)}',
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
