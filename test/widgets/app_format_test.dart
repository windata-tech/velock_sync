import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/widgets/app_format.dart';

void main() {
  group('AppFormat.errorSummary', () {
    test('maps provider HTTP codes to actionable Chinese sentences', () {
      expect(AppFormat.errorSummary('provider.http.401'), contains('重新授权'));
      expect(AppFormat.errorSummary('provider.http.403'), contains('权限'));
      expect(AppFormat.errorSummary('provider.http.404'), contains('不存在'));
      expect(AppFormat.errorSummary('provider.http.409'), contains('其他设备'));
    });

    test('maps network conditions to connection guidance', () {
      expect(
        AppFormat.errorSummary('sync.network.unreachable'),
        contains('远端'),
      );
      expect(AppFormat.errorSummary('sync.timeout'), contains('超时'));
      expect(
        AppFormat.errorSummary('ProviderRequestException(provider.http.503)'),
        isNot(contains('ProviderRequestException')),
      );
    });

    test(
      'missing history tells users to keep and reconnect the old backup',
      () {
        final message = AppFormat.errorSummary(
          'remote.velock_history_incomplete',
        );
        expect(message, contains('同步未完成'));
        expect(message, contains('不要删除旧备份'));
        expect(message, isNot(contains('remote.velock_history_incomplete')));
      },
    );

    test('never echoes raw codes for unknown values', () {
      expect(
        AppFormat.errorSummary('velock.some-future-code'),
        isNot(contains('some-future-code')),
      );
      expect(AppFormat.errorSummary(null), '同步未完成，请稍后重试。');
      expect(AppFormat.errorSummary(null, fallback: '自定义提示'), '自定义提示');
    });
  });

  group('AppFormat.relativeTime', () {
    final now = DateTime(2026, 9, 19, 10, 0, 0);

    test('recent times use minute granularity', () {
      expect(
        AppFormat.relativeTime(
          now.subtract(const Duration(seconds: 30)),
          now: now,
        ),
        '刚刚',
      );
      expect(
        AppFormat.relativeTime(
          now.subtract(const Duration(minutes: 9)),
          now: now,
        ),
        '9 分钟前',
      );
    });

    test('same-day times keep the clock, older ones keep the date', () {
      expect(
        AppFormat.relativeTime(
          now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        '今天 08:00',
      );
      expect(
        AppFormat.relativeTime(DateTime(2026, 9, 18, 22, 0), now: now),
        '昨天 22:00',
      );
      expect(
        AppFormat.relativeTime(DateTime(2026, 1, 5, 8, 30), now: now),
        '1月5日 08:30',
      );
      expect(
        AppFormat.relativeTime(DateTime(2025, 12, 31, 8, 30), now: now),
        '2025年12月31日',
      );
    });
  });

  group('AppFormat.bytes', () {
    test('uses 1024 steps with at most two decimals', () {
      expect(AppFormat.bytes(0), '0 B');
      expect(AppFormat.bytes(1024), '1 KB');
      expect(AppFormat.bytes(5 * 1024 * 1024), '5 MB');
      expect(AppFormat.bytes(50 * 1024 * 1024), '50 MB');
    });
  });
}
