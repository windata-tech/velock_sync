import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:velock_sync/core/json_parser.dart';
import 'package:velock_sync/features/connection/model/protocol_model.dart';

part '../../../generated/features/connection/model/connection_model.freezed.dart';

part '../../../generated/features/connection/model/connection_model.g.dart';

@freezed
sealed class CreateConnectionDto with _$CreateConnectionDto {
  factory CreateConnectionDto({required String name, String? description, required String source, required String target, required ProtocolModel protocol}) =
      _CreateConnectionDto;

  factory CreateConnectionDto.fromJson(Map<String, dynamic> json) => _$CreateConnectionDtoFromJson(json);
}

@freezed
sealed class ConnectionModel with _$ConnectionModel {
  factory ConnectionModel({
    required String id,
    required String name,
    String? description,
    required String source,
    String? sourceDescription,
    required String target,
    String? targetDescription,
    required ProtocolModel protocol,
    @TimestampParser() required DateTime createdAt,
    @TimestampParser() required DateTime updatedAt,
    required ConnectionStatus status,
  }) = _ConnectionModel;

  factory ConnectionModel.fromJson(Map<String, Object?> json) => _$ConnectionModelFromJson(json);
}

@freezed
sealed class ConnectionUiState with _$ConnectionUiState {
  const factory ConnectionUiState.initial() = _Initial;

  const factory ConnectionUiState.inProgress() = _InProgress;

  const factory ConnectionUiState.success({required ConnectionModel connection}) = _Success;

  const factory ConnectionUiState.failure({required FailedReason reason, String? message, Object? error}) = _Failure;
}

@JsonEnum()
enum ConnectionStatus {
  @JsonValue('pending')
  pending,
  @JsonValue('active')
  active,
  @JsonValue('inactive')
  inactive,
  @JsonValue('failed')
  failed,
}

@JsonEnum()
enum FailedReason {
  @JsonValue('bad_request') // 对应 HTTP 400
  badRequest,
  @JsonValue('server_error') // 对应 HTTP 5xx
  serverError,
  @JsonValue('resource_not_found') // 对应 HTTP 404
  resourceNotFound,
  @JsonValue('network_error')
  networkError,
  @JsonValue('timeout')
  timeout,
  @JsonValue('authentication_failed')
  authenticationFailed,
  @JsonValue('unknown_error')
  unknownError,
}
