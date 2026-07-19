// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../../../../features/connection/model/protocol_model.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

WebDavProtocolModel _$WebDavProtocolModelFromJson(Map<String, dynamic> json) =>
    WebDavProtocolModel(
      protocolType: $enumDecode(
        _$WebDavProtocolTypeEnumMap,
        json['protocolType'],
      ),
      address: json['address'] as String,
      port: json['port'] as String,
      username: json['username'] as String?,
      credentialRef: json['credentialRef'] as String?,
      path: json['path'] as String?,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$WebDavProtocolModelToJson(
  WebDavProtocolModel instance,
) => <String, dynamic>{
  'protocolType': _$WebDavProtocolTypeEnumMap[instance.protocolType]!,
  'address': instance.address,
  'port': instance.port,
  'username': instance.username,
  'credentialRef': instance.credentialRef,
  'path': instance.path,
  'runtimeType': instance.$type,
};

const _$WebDavProtocolTypeEnumMap = {
  WebDavProtocolType.http: 'http',
  WebDavProtocolType.https: 'https',
};

OAuthProtocolModel _$OAuthProtocolModelFromJson(Map<String, dynamic> json) =>
    OAuthProtocolModel(
      providerType: $enumDecode(
        _$RemoteProviderTypeEnumMap,
        json['providerType'],
      ),
      clientId: json['clientId'] as String,
      credentialRef: json['credentialRef'] as String,
      rootId: json['rootId'] as String,
      accountLabel: json['accountLabel'] as String?,
      $type: json['runtimeType'] as String?,
    );

Map<String, dynamic> _$OAuthProtocolModelToJson(OAuthProtocolModel instance) =>
    <String, dynamic>{
      'providerType': _$RemoteProviderTypeEnumMap[instance.providerType]!,
      'clientId': instance.clientId,
      'credentialRef': instance.credentialRef,
      'rootId': instance.rootId,
      'accountLabel': instance.accountLabel,
      'runtimeType': instance.$type,
    };

const _$RemoteProviderTypeEnumMap = {
  RemoteProviderType.webDav: 'webDav',
  RemoteProviderType.googleDrive: 'googleDrive',
  RemoteProviderType.oneDrive: 'oneDrive',
  RemoteProviderType.baiduNetdisk: 'baiduNetdisk',
  RemoteProviderType.aliyunDrive: 'aliyunDrive',
};
