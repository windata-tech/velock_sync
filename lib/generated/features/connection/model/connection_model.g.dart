// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/model/connection_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_CreateConnectionDto _$CreateConnectionDtoFromJson(Map<String, dynamic> json) =>
    _CreateConnectionDto(
      name: json['name'] as String,
      description: json['description'] as String?,
      source: json['source'] as String?,
      sourceDescription: json['source_description'] as String?,
      target: json['target'] as String?,
      targetDescription: json['target_description'] as String?,
      protocol: json['protocol'] == null
          ? null
          : ProtocolModel.fromJson(json['protocol'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$CreateConnectionDtoToJson(
  _CreateConnectionDto instance,
) => <String, dynamic>{
  'name': instance.name,
  'description': instance.description,
  'source': instance.source,
  'source_description': instance.sourceDescription,
  'target': instance.target,
  'target_description': instance.targetDescription,
  'protocol': instance.protocol?.toJson(),
};

_ConnectionModel _$ConnectionModelFromJson(Map<String, dynamic> json) =>
    _ConnectionModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      source: json['source'] as String,
      sourceDescription: json['source_description'] as String?,
      target: json['target'] as String,
      targetDescription: json['target_description'] as String?,
      protocol: ProtocolModel.fromJson(
        json['protocol'] as Map<String, dynamic>,
      ),
      createdAt: const TimestampParser().fromJson(
        (json['created_at'] as num).toInt(),
      ),
      updatedAt: const TimestampParser().fromJson(
        (json['updated_at'] as num).toInt(),
      ),
      status: $enumDecode(_$ConnectionStatusEnumMap, json['status']),
    );

Map<String, dynamic> _$ConnectionModelToJson(_ConnectionModel instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'description': instance.description,
      'source': instance.source,
      'source_description': instance.sourceDescription,
      'target': instance.target,
      'target_description': instance.targetDescription,
      'protocol': instance.protocol.toJson(),
      'created_at': const TimestampParser().toJson(instance.createdAt),
      'updated_at': const TimestampParser().toJson(instance.updatedAt),
      'status': _$ConnectionStatusEnumMap[instance.status]!,
    };

const _$ConnectionStatusEnumMap = {
  ConnectionStatus.pending: 'pending',
  ConnectionStatus.active: 'active',
  ConnectionStatus.inactive: 'inactive',
  ConnectionStatus.failed: 'failed',
};
