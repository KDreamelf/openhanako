import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../identity/experience_trust_anchor.dart';
import '../identity/keypair.dart';

class ExperienceReviewTrustAnchor {
  const ExperienceReviewTrustAnchor({
    required this.rootKeyId,
    required this.algorithm,
    required this.rootPublicKeyHex,
  });

  factory ExperienceReviewTrustAnchor.ph01() {
    return ExperienceReviewTrustAnchor(
      rootKeyId: ExperienceTrustAnchor.keyId,
      algorithm: ExperienceTrustAnchor.algorithm,
      rootPublicKeyHex: ExperienceTrustAnchor.rootPublicKeyHex(),
    );
  }

  final String rootKeyId;
  final String algorithm;
  final String rootPublicKeyHex;
}

class ExperienceReviewMaterials {
  const ExperienceReviewMaterials({
    this.schemaVersion = 'ph01.experience.review_materials.v1',
    required this.rootKeyId,
    required this.signatureAlgorithm,
    required this.signaturePayloadSha256,
    required this.managerReviewSignature,
    required this.signaturePayload,
    required this.managerCertificate,
  });

  final String schemaVersion;
  final String rootKeyId;
  final String signatureAlgorithm;
  final String signaturePayloadSha256;
  final String managerReviewSignature;
  final Map<String, dynamic> signaturePayload;
  final Map<String, dynamic> managerCertificate;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'root_key_id': rootKeyId,
    'signature_algorithm': signatureAlgorithm,
    'signature_payload_sha256': signaturePayloadSha256,
    'manager_review_signature': managerReviewSignature,
    'signature_payload': signaturePayload,
    'manager_certificate': managerCertificate,
  };

  static ExperienceReviewMaterials fromJson(Map<String, dynamic> json) {
    return ExperienceReviewMaterials(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.review_materials.v1',
      rootKeyId: json['root_key_id']?.toString() ?? '',
      signatureAlgorithm: json['signature_algorithm']?.toString() ?? '',
      signaturePayloadSha256:
          json['signature_payload_sha256']?.toString() ?? '',
      managerReviewSignature:
          json['manager_review_signature']?.toString() ?? '',
      signaturePayload: _mapValue(json['signature_payload']),
      managerCertificate: _mapValue(json['manager_certificate']),
    );
  }

  ExperienceReviewVerificationResult verify({
    required String experienceId,
    required String packageHash,
    required String publisherPubkey,
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) {
    final anchor = trustAnchor ?? ExperienceReviewTrustAnchor.ph01();
    if (schemaVersion != 'ph01.experience.review_materials.v1') {
      return const ExperienceReviewVerificationResult(false, '审核材料版本不支持');
    }
    if (rootKeyId != anchor.rootKeyId) {
      return const ExperienceReviewVerificationResult(false, 'Root key 不匹配');
    }
    if (signatureAlgorithm != anchor.algorithm) {
      return const ExperienceReviewVerificationResult(false, '审核签名算法不支持');
    }
    if (signaturePayload['schema_version'] !=
        'ph01.experience.review_payload.v1') {
      return const ExperienceReviewVerificationResult(
        false,
        '审核 payload 版本不支持',
      );
    }
    if (signaturePayload['experience_id'] != experienceId) {
      return const ExperienceReviewVerificationResult(false, '审核经验 ID 不匹配');
    }
    if (signaturePayload['package_hash_algorithm'] != 'sha256' ||
        signaturePayload['package_hash'] != packageHash) {
      return const ExperienceReviewVerificationResult(
        false,
        '审核 package.zip hash 不匹配',
      );
    }
    if (signaturePayload['publisher_pubkey'] != publisherPubkey) {
      return const ExperienceReviewVerificationResult(false, '审核发布者公钥不匹配');
    }
    if (signaturePayload['review_status'] != 'network') {
      return const ExperienceReviewVerificationResult(false, '经验未通过网络审核');
    }
    if (signaturePayload['signature_algorithm'] != anchor.algorithm) {
      return const ExperienceReviewVerificationResult(
        false,
        '审核 payload 签名算法不支持',
      );
    }

    final certPayload = _mapValue(managerCertificate['certificate']);
    if (certPayload.isEmpty) {
      return const ExperienceReviewVerificationResult(false, '缺少主控工作证书');
    }
    if (certPayload['issuer_root_key_id'] != anchor.rootKeyId ||
        certPayload['algorithm'] != anchor.algorithm) {
      return const ExperienceReviewVerificationResult(
        false,
        '主控工作证书与 Root 不匹配',
      );
    }
    if (managerCertificate['signature_algorithm'] != anchor.algorithm) {
      return const ExperienceReviewVerificationResult(false, '主控证书签名算法不支持');
    }
    final certTimeCheck = _verifyCertificateTime(certPayload, now);
    if (certTimeCheck != null) return certTimeCheck;

    final certPayloadBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(certPayload)),
    );
    final certHash = _sha256Hex(certPayloadBytes);
    final declaredCertHash = managerCertificate['signature_payload_sha256']
        ?.toString();
    if (declaredCertHash != null &&
        declaredCertHash.isNotEmpty &&
        declaredCertHash != certHash) {
      return const ExperienceReviewVerificationResult(
        false,
        '主控证书 payload hash 不匹配',
      );
    }
    final rootSignature = managerCertificate['root_signature_hex']?.toString();
    if (rootSignature == null || rootSignature.isEmpty) {
      return const ExperienceReviewVerificationResult(false, '缺少 Root 签名');
    }
    if (!_verifySignature(
      publicKeyHex: anchor.rootPublicKeyHex,
      message: certPayloadBytes,
      signatureHex: rootSignature,
    )) {
      return const ExperienceReviewVerificationResult(false, 'Root 验证主控证书失败');
    }

    final payloadBytes = Uint8List.fromList(
      utf8.encode(jsonEncode(signaturePayload)),
    );
    if (signaturePayloadSha256 != _sha256Hex(payloadBytes)) {
      return const ExperienceReviewVerificationResult(
        false,
        '审核 payload hash 不匹配',
      );
    }
    if (!_verifySignature(
      publicKeyHex: certPayload['public_key_hex']?.toString() ?? '',
      message: payloadBytes,
      signatureHex: managerReviewSignature,
    )) {
      return const ExperienceReviewVerificationResult(false, '管理端审核签名验证失败');
    }
    return const ExperienceReviewVerificationResult(true, '审核签名验证通过');
  }
}

class ExperienceReviewVerificationResult {
  const ExperienceReviewVerificationResult(this.ok, this.message);
  final bool ok;
  final String message;
}

ExperienceReviewVerificationResult? _verifyCertificateTime(
  Map<String, dynamic> certPayload,
  DateTime? now,
) {
  final notBefore = DateTime.tryParse(
    certPayload['not_before']?.toString() ?? '',
  );
  final notAfter = DateTime.tryParse(
    certPayload['not_after']?.toString() ?? '',
  );
  if (notBefore == null || notAfter == null) {
    return const ExperienceReviewVerificationResult(false, '主控证书缺少有效期');
  }
  final timestamp = (now ?? DateTime.now()).toUtc();
  if (timestamp.isBefore(notBefore.toUtc()) ||
      timestamp.isAfter(notAfter.toUtc())) {
    return const ExperienceReviewVerificationResult(false, '主控证书不在有效期内');
  }
  return null;
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

bool _verifySignature({
  required String publicKeyHex,
  required Uint8List message,
  required String signatureHex,
}) {
  try {
    return HanakoKeyPair.verify(
      message: message,
      signature64: _hexDecode(signatureHex),
      publicKeyBytes65: _hexDecode(publicKeyHex),
    );
  } catch (_) {
    return false;
  }
}

String _sha256Hex(List<int> data) => sha256
    .convert(data)
    .bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

Uint8List _hexDecode(String hex) {
  final clean = hex.trim().replaceAll(' ', '');
  if (clean.length.isOdd) throw ArgumentError('hex 长度必须为偶数');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
