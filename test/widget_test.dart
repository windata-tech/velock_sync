import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/core/app_router.dart';

void main() {
  test('routes retain stable sync workspace paths', () {
    expect(AppRoutes.dashboard.path, '/dashboard');
    expect(AppRoutes.connections.path, '/connections');
  });
}
