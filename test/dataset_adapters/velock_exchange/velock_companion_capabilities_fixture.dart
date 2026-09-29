import 'dart:convert';
import 'dart:io';

/// Writes the descriptor Velock 2.0.7+ publishes at start-up, so fixtures that
/// model a current Velock pass the companion-version gate.
Future<void> writeVelockCompanionCapabilities(
  Directory exchangeRoot, {
  List<String> capabilities = const [
    'join-request-v2',
    'cloud-recovery-file-v1',
    'route-sync-settings',
    'current-snapshot-v2',
    'outbox-status-v1',
  ],
  Map<String, Object?> extra = const {},
}) async {
  final file = File('${exchangeRoot.path}/Control/Capabilities.json');
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'schema': 1,
      'app': 'velock',
      'version': '2.0.7',
      'build': 12,
      'capabilities': capabilities,
      ...extra,
    }),
  );
}
