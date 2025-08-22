// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../domain/sync_task.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SyncTask _$SyncTaskFromJson(Map<String, dynamic> json) => _SyncTask(
  id: json['id'] as String,
  name: json['name'] as String,
  description: json['description'] as String,
  source: json['source'] as String,
  target: json['target'] as String,
  createdAt: const TimestampParser().fromJson(
    (json['created_at'] as num).toInt(),
  ),
  updatedAt: const TimestampParser().fromJson(
    (json['updated_at'] as num).toInt(),
  ),
  status: $enumDecode(_$SyncTaskStatusEnumMap, json['status']),
);

Map<String, dynamic> _$SyncTaskToJson(_SyncTask instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'description': instance.description,
  'source': instance.source,
  'target': instance.target,
  'created_at': const TimestampParser().toJson(instance.createdAt),
  'updated_at': const TimestampParser().toJson(instance.updatedAt),
  'status': _$SyncTaskStatusEnumMap[instance.status]!,
};

const _$SyncTaskStatusEnumMap = {
  SyncTaskStatus.pending: 'pending',
  SyncTaskStatus.inProgress: 'in_progress',
  SyncTaskStatus.completed: 'completed',
  SyncTaskStatus.failed: 'failed',
};
