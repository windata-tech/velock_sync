// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/model/protocol_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

WebDavProtocolModel _$WebDavProtocolModelFromJson(Map<String, dynamic> json) =>
    WebDavProtocolModel(
      protocolType: $enumDecode(
        _$WebDavProtocolTypeEnumMap,
        json['protocol_type'],
      ),
      address: json['address'] as String,
      port: json['port'] as String,
      username: json['username'] as String?,
      password: json['password'] as String?,
      path: json['path'] as String?,
    );

Map<String, dynamic> _$WebDavProtocolModelToJson(
  WebDavProtocolModel instance,
) => <String, dynamic>{
  'protocol_type': _$WebDavProtocolTypeEnumMap[instance.protocolType]!,
  'address': instance.address,
  'port': instance.port,
  'username': instance.username,
  'password': instance.password,
  'path': instance.path,
};

const _$WebDavProtocolTypeEnumMap = {
  WebDavProtocolType.http: 'http',
  WebDavProtocolType.https: 'https',
};
