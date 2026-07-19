import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/contracts/sync_dataset_adapter.dart';
import 'package:velock_sync/sync_core/crypto/generic_vault_acknowledgement.dart';

void main() {
  test(
    'signs a canonical V1 acknowledgement that verifies with the device key',
    () async {
      final signer = GenericVaultAcknowledgementSigner();
      final keyPair = await Ed25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      final artifact = await signer.sign(
        draft: GenericVaultAcknowledgementDraft(
          vaultId: 'vault-1',
          consumerDeviceId: 'consumer-1',
          producerDeviceId: 'producer-1',
          appliedThroughSequence: 42,
          createdAt: DateTime.utc(2026, 7, 15, 12, 10),
        ),
        signingKey: keyPair,
      );
      final bytes = await _read(artifact);

      expect(
        await signer.verify(
          acknowledgement: bytes,
          trustedPublicKey: publicKey,
        ),
        isTrue,
      );
      expect(
        jsonDecode(utf8.decode(bytes)),
        containsPair('appliedThroughSequence', 42),
      );
      expect(
        await _read(
          await signer.sign(
            draft: GenericVaultAcknowledgementDraft(
              vaultId: 'vault-1',
              consumerDeviceId: 'consumer-1',
              producerDeviceId: 'producer-1',
              appliedThroughSequence: 42,
              createdAt: DateTime.utc(2026, 7, 15, 12, 10),
            ),
            signingKey: keyPair,
          ),
        ),
        bytes,
      );
    },
  );
}

Future<Uint8List> _read(ImmutableArtifact artifact) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in await artifact.openRead()) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
