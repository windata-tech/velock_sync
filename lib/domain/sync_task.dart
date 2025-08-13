import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:velock_sync/core/json_parser.dart';

part '../generated/domain/sync_task.g.dart';

part '../generated/domain/sync_task.freezed.dart';

@freezed
sealed class SyncTask with _$SyncTask {
  factory SyncTask({
    required String id,
    required String name,
    required String description,
    required String source,
    required String target,
    @TimestampParser() required DateTime createdAt,
    @TimestampParser() required DateTime updatedAt,
    required SyncTaskStatus status,
  }) = _SyncTask;

  factory SyncTask.fromJson(Map<String, Object?> json) => _$SyncTaskFromJson(json);
}

@JsonEnum()
enum SyncTaskStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('in_progress')
  inProgress,
  @JsonValue('completed')
  completed,
  @JsonValue('failed')
  failed,
}
