import 'package:velock_sync/sync_profiles/model/sync_profile_envelope.dart';

/// Validates and defensively copies decoded relative WebDAV path segments.
///
/// A profile-level remote scope is always relative to one unchanged connection.
/// Both the Velock backup profile and the Selected Folder (file sync) profile
/// share this single rule so a relocation saved by one surface cannot be
/// interpreted differently by a sync run.
List<String> canonicalRemoteRootSegments(Iterable<String> segments) {
  final values = List<String>.of(segments);
  for (final segment in values) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains('\\') ||
        segment.runes.any(
          (rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
        )) {
      throw const FormatException(
        'Sync profile remote root segments are invalid.',
      );
    }
  }
  return List<String>.unmodifiable(values);
}

/// Reads the remote scope a profile envelope stored (missing = connection root).
List<String> envelopeRemoteRootSegments(SyncProfileEnvelope profile) {
  final raw = profile.dataset['remoteRootSegments'];
  if (raw is! List) return const [];
  return canonicalRemoteRootSegments(raw.whereType<String>());
}
