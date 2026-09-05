import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_exchange_v1_contract.dart';
import 'package:velock_sync/dataset_adapters/velock_exchange/velock_pairing_control_plane.dart';

class VelockPairingSession {
  const VelockPairingSession({required this.descriptor, required this.request});

  final VelockPairingDescriptor descriptor;
  final VelockPairingControlRequest request;
}

class VelockPairingSessionState {
  const VelockPairingSessionState({required this.status, this.response});

  final VelockPairingControlStatus status;
  final VelockPairingControlResponse? response;

  bool get isApproved =>
      status == VelockPairingControlStatus.approved && response != null;
}

abstract interface class VelockPairingSessionService {
  Future<VelockPairingSession> begin({
    required VelockPairingDescriptor descriptor,
    required String syncAppInstanceId,
  });
  Future<VelockPairingSessionState> inspect(VelockPairingSession session);
  Future<void> reopen(VelockPairingSession session);
  Future<void> acknowledge(VelockPairingSession session);
}

/// Drives a single challenge without ever creating a producer identity or key.
/// An approved response is returned only after expiry, binding and Ed25519
/// verification. The caller acknowledges only after its final profile save.
class PlatformVelockPairingSessionService
    implements VelockPairingSessionService {
  PlatformVelockPairingSessionService({
    required VelockPairingControlChannel control,
    DateTime Function()? now,
    String Function()? nextId,
    Future<bool> Function(Uri uri)? launchVelock,
  }) : _control = control,
       _now = now ?? DateTime.now,
       _nextId = nextId ?? const Uuid().v4,
       _launchVelock = launchVelock ?? launchUrl;

  final VelockPairingControlChannel _control;
  final DateTime Function() _now;
  final String Function() _nextId;
  final Future<bool> Function(Uri uri) _launchVelock;

  @override
  Future<VelockPairingSession> begin({
    required VelockPairingDescriptor descriptor,
    required String syncAppInstanceId,
  }) async {
    final createdAt = _now().toUtc();
    final request = VelockPairingControlRequest(
      requestId: _nextId(),
      challenge: _nextId(),
      producerId: descriptor.producerId,
      producerPublicKeyId: descriptor.producerPublicKeyId,
      exchangeBindingId: descriptor.exchangeBindingId,
      syncAppInstanceId: syncAppInstanceId,
      createdAt: createdAt,
      expiresAt: createdAt.add(VelockExchangeV1Contract.pairingRequestTtl),
    );
    final status = await _control.submitPairingRequest(request);
    if (status != VelockPairingControlStatus.pending) {
      throw const VelockPairingSessionException(
        'invalid_pairing_request_state',
      );
    }
    return VelockPairingSession(descriptor: descriptor, request: request);
  }

  @override
  Future<VelockPairingSessionState> inspect(
    VelockPairingSession session,
  ) async {
    if (!_now().toUtc().isBefore(session.request.expiresAt)) {
      return const VelockPairingSessionState(
        status: VelockPairingControlStatus.expired,
      );
    }
    final result = await _control.queryPairingResponse(
      session.request.requestId,
    );
    final response = result.response;
    if (result.status == VelockPairingControlStatus.approved) {
      if (response == null ||
          !await response.verify(
            descriptor: session.descriptor,
            request: session.request,
            now: _now,
          )) {
        throw const VelockPairingSessionException('invalid_pairing_response');
      }
    } else if (response != null) {
      throw const VelockPairingSessionException('invalid_pairing_response');
    }
    return VelockPairingSessionState(status: result.status, response: response);
  }

  @override
  Future<void> reopen(VelockPairingSession session) async {
    final launched = await _launchVelock(
      Uri(
        scheme: 'velock',
        host: 'sync-pairing',
        queryParameters: {'requestId': session.request.requestId},
      ),
    );
    if (!launched) {
      throw const VelockPairingSessionException('pairing_app_unavailable');
    }
  }

  @override
  Future<void> acknowledge(VelockPairingSession session) =>
      _control.acknowledgePairing(session.request.requestId);
}

class VelockPairingSessionException implements Exception {
  const VelockPairingSessionException(this.code);

  final String code;
}
