import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:hanako/identity/identity.dart';
import 'package:path/path.dart' as p;

void main() {
  test('经验网络根公钥与公共证书一致', () {
    final certPath = p.normalize(
      p.join(
        Directory.current.path,
        '..',
        'certs',
        'public',
        'experience-network',
        'root-certificate.json',
      ),
    );
    final certFile = File(certPath);
    expect(certFile.existsSync(), isTrue, reason: '缺少公共根证书：$certPath');

    final cert =
        jsonDecode(certFile.readAsStringSync()) as Map<String, dynamic>;
    expect(ExperienceTrustAnchor.keyId, cert['key_id']);
    expect(ExperienceTrustAnchor.algorithm, cert['algorithm']);

    final bytes = ExperienceTrustAnchor.rootPublicKeyBytes();
    expect(bytes.length, 65);
    expect(bytes.first, 0x04);
    expect(ExperienceTrustAnchor.rootPublicKeyHex(), cert['public_key_hex']);

    final fingerprint = sha256
        .convert(bytes)
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(fingerprint, cert['fingerprint_sha256']);
    expect(
      ExperienceTrustAnchor.rootPublicKeyFingerprintSha256Hex(),
      fingerprint,
    );
  });
}
