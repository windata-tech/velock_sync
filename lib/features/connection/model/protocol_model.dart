// ignore_for_file: invalid_annotation_target

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:velock_sync/sync_core/model/sync_models.dart';

part '../../../generated/features/connection/model/protocol_model.freezed.dart';

part '../../../generated/features/connection/model/protocol_model.g.dart';

@freezed
sealed class ProtocolModel with _$ProtocolModel {
  const factory ProtocolModel.webDav({
    @JsonKey(name: 'protocolType') required WebDavProtocolType protocolType,
    required String address,
    required String port,
    String? username,
    @JsonKey(name: 'credentialRef') String? credentialRef,
    String? path,
  }) = WebDavProtocolModel;

  /// OAuth targets store only public registration details and an opaque secure
  /// storage reference. Refresh tokens never enter connection JSON.
  const factory ProtocolModel.oauth({
    @JsonKey(name: 'providerType') required RemoteProviderType providerType,
    @JsonKey(name: 'clientId') required String clientId,
    @JsonKey(name: 'credentialRef') required String credentialRef,
    @JsonKey(name: 'rootId') required String rootId,
    @JsonKey(name: 'accountLabel') String? accountLabel,
  }) = OAuthProtocolModel;

  // 未来可以轻松扩展其他协议
  // const factory ProtocolModel.ftp(...) = FtpProtocolModel;
  // const factory ProtocolModel.s3(...) = S3ProtocolModel;

  // fromJson 工厂构造函数现在属于基类 ProtocolModel
  factory ProtocolModel.fromJson(Map<String, Object?> json) =>
      _$ProtocolModelFromJson(json);
}

extension ProtocolModelConnectionDetails on ProtocolModel {
  String get targetLabel => switch (this) {
    WebDavProtocolModel(:final address, :final port) => '$address:$port',
    OAuthProtocolModel(
      :final providerType,
      :final accountLabel,
      :final rootId,
    ) =>
      accountLabel?.trim().isNotEmpty == true
          ? accountLabel!
          : '${providerType.name}:$rootId',
  };

  String? get credentialReference => switch (this) {
    WebDavProtocolModel(:final credentialRef) => credentialRef,
    OAuthProtocolModel(:final credentialRef) => credentialRef,
  };
}

// 这个 Enum 的定义是正确的，保持不变
@JsonEnum()
enum WebDavProtocolType {
  @JsonValue('http')
  http,
  @JsonValue('https')
  https,
}
