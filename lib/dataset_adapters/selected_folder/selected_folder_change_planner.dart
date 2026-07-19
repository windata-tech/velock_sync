import 'dart:io';

import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_scanner.dart';
import 'package:velock_sync/dataset_adapters/selected_folder/selected_folder_storage.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

enum SelectedFolderChangeType { upsert, delete }

/// A local change awaiting encryption and protocol packaging. The relative path
/// is intentionally confined to this dataset adapter and must be protected by
/// the generic-vault encoder before any remote publication.
class SelectedFolderChange {
  const SelectedFolderChange({
    required this.type,
    required this.entry,
    this.blobSource,
  });

  final SelectedFolderChangeType type;
  final FolderScanEntry entry;

  /// Present only for file upserts. The source is replayable and is never
  /// handed directly to a remote provider.
  final SelectedFolderReadableFile? blobSource;
}

class SelectedFolderChangePlan {
  const SelectedFolderChangePlan(this.changes);

  final List<SelectedFolderChange> changes;

  bool get isEmpty => changes.isEmpty;

  SelectedFolderChangePlan take(int count) {
    if (count < 1) throw ArgumentError.value(count, 'count');
    return SelectedFolderChangePlan(List.unmodifiable(changes.take(count)));
  }
}

/// Converts a completed local scan into the exact set of changes that a
/// generic-vault crypto/operation encoder must package. It owns no provider
/// dependency and never serializes cleartext paths into remote artifacts.
class SelectedFolderChangePlanner {
  const SelectedFolderChangePlanner();

  SelectedFolderChangePlan plan({
    Directory? root,
    SelectedFolderStorage? storage,
    required SelectedFolderScanResult scan,
  }) {
    if (storage == null && root == null) {
      throw ArgumentError('Either root or storage is required.');
    }
    final folder = storage ?? LocalSelectedFolderStorage(root!);
    final changes = <SelectedFolderChange>[];
    for (final entry in scan.upsertedEntries) {
      final blobSource = entry.type == FolderEntryType.file
          ? folder.file(entry.relativePath)
          : null;
      changes.add(
        SelectedFolderChange(
          type: SelectedFolderChangeType.upsert,
          entry: entry,
          blobSource: blobSource,
        ),
      );
    }
    for (final entry in scan.deletedEntries) {
      changes.add(
        SelectedFolderChange(
          type: SelectedFolderChangeType.delete,
          entry: entry,
        ),
      );
    }
    return SelectedFolderChangePlan(List.unmodifiable(changes));
  }
}
