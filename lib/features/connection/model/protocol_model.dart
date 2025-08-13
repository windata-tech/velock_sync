import 'package:freezed_annotation/freezed_annotation.dart';

part '../../../generated/features/connection/model/protocol_model.freezed.dart';

part '../../../generated/features/connection/model/protocol_model.g.dart';

@freezed
sealed class ProtocolModel with _$ProtocolModel {
  const factory ProtocolModel.webDav({
    required WebDavProtocolType protocolType,
    required String address,
    required String port,
    String? username,
    String? password,
    String? path,
  }) = WebDavProtocolModel;

  // 未来可以轻松扩展其他协议
  // const factory ProtocolModel.ftp(...) = FtpProtocolModel;
  // const factory ProtocolModel.s3(...) = S3ProtocolModel;

  // fromJson 工厂构造函数现在属于基类 ProtocolModel
  factory ProtocolModel.fromJson(Map<String, Object?> json) => _$ProtocolModelFromJson(json);
}

// 这个 Enum 的定义是正确的，保持不变
@JsonEnum()
enum WebDavProtocolType {
  @JsonValue('http')
  http,
  @JsonValue('https')
  https,
}
