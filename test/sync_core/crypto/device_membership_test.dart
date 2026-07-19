import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:velock_sync/sync_core/crypto/device_membership.dart';

void main() {
  group('DeviceMembershipSigner', () {
    test('signs and verifies a canonical active member document', () async {
      final signer = DeviceMembershipSigner();
      final issuer = await Ed25519().newKeyPair();
      final issuerPublic = await issuer.extractPublicKey();
      final memberKey = await Ed25519().newKeyPair();
      final memberPublic = await memberKey.extractPublicKey();
      final draft = DeviceMembershipDraft(
        vaultId: 'vault-1',
        deviceId: 'device-2',
        signingPublicKey: Uint8List.fromList(memberPublic.bytes),
        status: DeviceMembershipStatus.active,
        issuedAt: DateTime.utc(2026, 7, 15, 12),
        issuedByDeviceId: 'device-1',
        friendlyNameCiphertext: base64UrlEncode([1, 2, 3]).replaceAll('=', ''),
      );

      final bytes = await signer.sign(draft: draft, issuerSigningKey: issuer);
      final verified = await signer.verify(
        member: bytes,
        expectedVaultId: 'vault-1',
        expectedIssuerDeviceId: 'device-1',
        trustedIssuerPublicKey: issuerPublic,
      );

      expect(verified, isNotNull);
      expect(verified!.deviceId, 'device-2');
      expect(verified.status, DeviceMembershipStatus.active);
      expect(
        jsonDecode(utf8.decode(bytes)),
        containsPair('protocolVersion', 1),
      );
    });

    test('rejects tampered member documents and an untrusted issuer', () async {
      final signer = DeviceMembershipSigner();
      final issuer = await Ed25519().newKeyPair();
      final wrongIssuer = await Ed25519().newKeyPair();
      final issuerPublic = await issuer.extractPublicKey();
      final wrongPublic = await wrongIssuer.extractPublicKey();
      final memberPublic = await (await Ed25519().newKeyPair())
          .extractPublicKey();
      final bytes = await signer.sign(
        draft: DeviceMembershipDraft(
          vaultId: 'vault-1',
          deviceId: 'device-2',
          signingPublicKey: Uint8List.fromList(memberPublic.bytes),
          status: DeviceMembershipStatus.revoked,
          issuedAt: DateTime.utc(2026, 7, 15, 12),
          issuedByDeviceId: 'device-1',
        ),
        issuerSigningKey: issuer,
      );

      expect(
        await signer.verify(
          member: bytes,
          expectedVaultId: 'vault-1',
          expectedIssuerDeviceId: 'device-1',
          trustedIssuerPublicKey: wrongPublic,
        ),
        isNull,
      );
      final tampered = Uint8List.fromList(
        utf8.encode(utf8.decode(bytes).replaceFirst('device-2', 'device-3')),
      );
      expect(
        await signer.verify(
          member: tampered,
          expectedVaultId: 'vault-1',
          expectedIssuerDeviceId: 'device-1',
          trustedIssuerPublicKey: issuerPublic,
        ),
        isNull,
      );
    });
  });
}
