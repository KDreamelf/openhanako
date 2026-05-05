import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class ExperienceTrustAnchor {
  ExperienceTrustAnchor._();

  static const String keyId = 'ph01-exp-root-20260504';
  static const String algorithm = 'secp256k1_ecdsa_sha256_rs64';

  static Uint8List rootPublicKeyBytes() {
    final out = Uint8List(_encoded.length);
    for (var i = 0; i < _encoded.length; i++) {
      final mixed = (_encoded[i] - ((i * 17 + 91) & 0xff)) & 0xff;
      out[i] = mixed ^ _mask[i % _mask.length];
    }
    return out;
  }

  static String rootPublicKeyHex() {
    final bytes = rootPublicKeyBytes();
    final buffer = StringBuffer();
    for (final byte in bytes) {
      _writeHexByte(buffer, byte);
    }
    return buffer.toString();
  }

  static String rootPublicKeyFingerprintSha256Hex() {
    final digest = sha256.convert(rootPublicKeyBytes());
    final buffer = StringBuffer();
    for (final byte in digest.bytes) {
      _writeHexByte(buffer, byte);
    }
    return buffer.toString();
  }

  static void _writeHexByte(StringBuffer buffer, int value) {
    const hex = '0123456789abcdef';
    buffer
      ..write(hex[(value >> 4) & 0x0f])
      ..write(hex[value & 0x0f]);
  }

  static const List<int> _mask = <int>[
    0x91,
    0x27,
    0x6d,
    0xc4,
    0x38,
    0xa5,
    0x0f,
    0xde,
    0x52,
    0xb9,
    0x04,
    0x73,
    0xe1,
    0x16,
    0x8a,
    0x2c,
    0xf7,
    0x49,
    0xbd,
  ];

  static const List<int> _encoded = <int>[
    0xf0,
    0xaa,
    0x70,
    0x79,
    0x0e,
    0x08,
    0x02,
    0x57,
    0x29,
    0xe7,
    0x43,
    0xd9,
    0x6d,
    0x77,
    0xf7,
    0x69,
    0x6d,
    0x5d,
    0x83,
    0x37,
    0x93,
    0xb6,
    0xe3,
    0x21,
    0x66,
    0xe9,
    0x9a,
    0x24,
    0x6b,
    0x6b,
    0x9c,
    0x8c,
    0xa9,
    0x04,
    0x77,
    0x32,
    0x80,
    0x57,
    0x47,
    0xfc,
    0x56,
    0x82,
    0x41,
    0xdd,
    0x4d,
    0x9e,
    0xdf,
    0x0c,
    0x3c,
    0xd7,
    0xef,
    0x18,
    0x71,
    0x66,
    0x06,
    0x72,
    0x1b,
    0x9a,
    0x5c,
    0x7f,
    0xfe,
    0xf1,
    0x26,
    0x9b,
    0xef,
  ];
}
