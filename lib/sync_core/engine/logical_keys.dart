/// Generates and validates provider-neutral keys defined by Sync Protocol V1.
abstract final class LogicalKeys {
  static const _root = 'velock-sync/v1';

  static String protocol(String vaultId) =>
      '$_root/${_id(vaultId, 'vaultId')}/protocol.json';

  static String member(String vaultId, String deviceId) =>
      '$_root/${_id(vaultId, 'vaultId')}/members/${_id(deviceId, 'deviceId')}.member';

  static String blob(String vaultId, String blobId) {
    final id = _id(blobId, 'blobId');
    return '$_root/${_id(vaultId, 'vaultId')}/blobs/${id.substring(0, 2)}/$id.blob';
  }

  static String batchEnvelope(
    String vaultId,
    String deviceId,
    int sequence,
    String batchId,
  ) =>
      '${_deviceRoot(vaultId, deviceId)}/batches/${formatSequence(sequence)}/${_id(batchId, 'batchId')}/envelope.json';

  static String batchOperations(
    String vaultId,
    String deviceId,
    int sequence,
    String batchId,
  ) =>
      '${_deviceRoot(vaultId, deviceId)}/batches/${formatSequence(sequence)}/${_id(batchId, 'batchId')}/operations.enc';

  static String commit(
    String vaultId,
    String deviceId,
    int sequence,
    String batchId,
  ) =>
      '${_deviceRoot(vaultId, deviceId)}/commits/${formatSequence(sequence)}-${_id(batchId, 'batchId')}.commit';

  static String acknowledgement(
    String vaultId,
    String consumerDeviceId,
    String producerDeviceId,
    int sequence,
  ) =>
      '$_root/${_id(vaultId, 'vaultId')}/acknowledgements/${_id(consumerDeviceId, 'consumerDeviceId')}/'
      '${_id(producerDeviceId, 'producerDeviceId')}/${formatSequence(sequence)}.ack';

  static String checkpointEnvelope(String vaultId, String checkpointId) =>
      '${checkpointPrefix(vaultId, checkpointId)}/envelope.json';

  static String checkpointPart(
    String vaultId,
    String checkpointId,
    int partNumber,
  ) {
    if (partNumber < 1) {
      throw ArgumentError.value(partNumber, 'partNumber', 'must be positive');
    }
    return '${checkpointPrefix(vaultId, checkpointId)}/parts/${partNumber.toString().padLeft(8, '0')}.enc';
  }

  static String checkpointCommit(String vaultId, String checkpointId) =>
      '${checkpointPrefix(vaultId, checkpointId)}/checkpoint.commit';

  static String checkpointPrefix(String vaultId, String checkpointId) =>
      '$_root/${_id(vaultId, 'vaultId')}/checkpoints/${_id(checkpointId, 'checkpointId')}';

  static String checkpointsPrefix(String vaultId) =>
      '$_root/${_id(vaultId, 'vaultId')}/checkpoints/';

  static String vaultPrefix(String vaultId) =>
      '$_root/${_id(vaultId, 'vaultId')}/';

  static String garbageCollectionManifest(String vaultId, String planId) =>
      '${vaultPrefix(vaultId)}gc/${_id(planId, 'planId')}.manifest.json';

  static String deviceCommitsPrefix(String vaultId, String deviceId) =>
      '${_deviceRoot(vaultId, deviceId)}/commits/';

  static String formatSequence(int sequence) {
    if (sequence < 1) {
      throw ArgumentError.value(sequence, 'sequence', 'must be positive');
    }
    return sequence.toString().padLeft(20, '0');
  }

  static String _deviceRoot(String vaultId, String deviceId) =>
      '$_root/${_id(vaultId, 'vaultId')}/devices/${_id(deviceId, 'deviceId')}';

  static String _id(String value, String name) {
    if (value.isEmpty ||
        value.contains('/') ||
        value.contains('..') ||
        value.contains('\\')) {
      throw ArgumentError.value(
        value,
        name,
        'must be a non-empty opaque identifier',
      );
    }
    return value;
  }
}
