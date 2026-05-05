// lib/identity/secure_keystore.dart
//
// 子体长期身份 vault。
//
// Windows 默认使用 DPAPI 保护随机 DEK，避免 keystore 文件被复制后遭离线
// 爆破；私钥和助记词 ID 组由 DEK 通过 AES-256-GCM 加密后落盘。运行期间
// 解锁一次后可把身份保存在内存中，用于高频签名和通信密钥协商。
//
// 非 Windows / 测试路径保留 PIN + PBKDF2 的文件实现作为 fallback，不作为
// Windows 生产默认。

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/pointycastle.dart' show Pbkdf2Parameters;

const _nonceLen = 12;
const _tagLen = 16;
const _dekLen = 32;
const _pbkdf2SaltLen = 16;
const _pbkdf2Iter = 200000;
const _vaultSchema = 1;
const _dpapiEntropy = 'PH01.Hanako.IdentityVault.v1';

/// 长期身份 vault 的明文结构。外层必须由 [SecureKeystore] 加密保护。
class IdentityVault {
  IdentityVault({
    required this.privateKey,
    this.mnemonicIds,
    this.wordlistVersion,
  }) {
    if (privateKey.length != 32) {
      throw ArgumentError('私钥必须为 32 字节，收到 ${privateKey.length}');
    }
    final ids = mnemonicIds;
    if (ids != null) {
      if (ids.length != 12) {
        throw ArgumentError('助记词 ID 组必须为 12 个值，收到 ${ids.length}');
      }
      for (final id in ids) {
        if (id < 0 || id > 2047) {
          throw ArgumentError('助记词 ID 越界：$id');
        }
      }
    }
  }

  final Uint8List privateKey;
  final List<int>? mnemonicIds;
  final String? wordlistVersion;

  Map<String, dynamic> toJson() => {
    'schema': _vaultSchema,
    'private_key_hex': _hexEncode(privateKey),
    if (mnemonicIds != null)
      'mnemonic': {'wordlist': wordlistVersion, 'ids': mnemonicIds},
  };

  factory IdentityVault.fromJson(Map<String, dynamic> json) {
    final schema = (json['schema'] as num?)?.toInt() ?? 0;
    if (schema != _vaultSchema) {
      throw StateError('不支持的身份 vault schema：$schema');
    }
    final mnemonic = json['mnemonic'];
    List<int>? ids;
    String? wordlist;
    if (mnemonic is Map) {
      final rawIds = mnemonic['ids'];
      if (rawIds is List) {
        ids = rawIds.map((value) => (value as num).toInt()).toList();
      }
      final rawWordlist = mnemonic['wordlist'];
      if (rawWordlist is String && rawWordlist.isNotEmpty) {
        wordlist = rawWordlist;
      }
    }
    return IdentityVault(
      privateKey: _hexDecode(json['private_key_hex'] as String),
      mnemonicIds: ids,
      wordlistVersion: wordlist,
    );
  }
}

/// 抽象接口：方便单元测试用 in-memory / 文件实现替换。
abstract class SecureKeystore {
  Future<bool> exists();

  Future<void> writeVault(IdentityVault vault, {String? pin});

  Future<IdentityVault> readVault({String? pin});

  Future<void> writePrivateKey(Uint8List privateKey, {String? pin}) {
    return writeVault(IdentityVault(privateKey: privateKey), pin: pin);
  }

  Future<Uint8List> readPrivateKey({String? pin}) async {
    final vault = await readVault(pin: pin);
    return vault.privateKey;
  }

  Future<void> deleteAll();
}

class InvalidPinException implements Exception {
  const InvalidPinException();
  @override
  String toString() => 'InvalidPinException: PIN 不正确，无法解密身份 vault';
}

class KeystoreAccessDeniedException implements Exception {
  const KeystoreAccessDeniedException(this.message);
  final String message;
  @override
  String toString() => 'KeystoreAccessDeniedException: $message';
}

/// 平台默认实现：Windows 使用 DPAPI，其余平台退回文件加密。
class PlatformSecureKeystore extends SecureKeystore {
  PlatformSecureKeystore({required Directory hanaHome})
    : _inner = Platform.isWindows
          ? WindowsDpapiKeystore(hanaHome: hanaHome)
          : FileSecureKeystore(hanaHome: hanaHome);

  final SecureKeystore _inner;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<void> writeVault(IdentityVault vault, {String? pin}) =>
      _inner.writeVault(vault, pin: pin);

  @override
  Future<IdentityVault> readVault({String? pin}) => _inner.readVault(pin: pin);

  @override
  Future<void> deleteAll() => _inner.deleteAll();
}

/// Windows DPAPI vault：DEK 由当前 Windows 用户 + 当前设备保护。
class WindowsDpapiKeystore extends SecureKeystore {
  WindowsDpapiKeystore({required this.hanaHome, this.promptOnRead = true});

  final Directory hanaHome;

  /// 是否在解封 DPAPI 数据时请求系统提示。DPAPI 不等同于强制 Windows Hello；
  /// 它由 Windows 决定实际 UI。测试中应设为 false。
  final bool promptOnRead;

  File get _file => File(p.join(hanaHome.path, 'identity', 'keystore.dpapi'));
  File get _legacyFile =>
      File(p.join(hanaHome.path, 'identity', 'keystore.bin'));

  @override
  Future<bool> exists() async =>
      await _file.exists() || await _legacyFile.exists();

  @override
  Future<void> writeVault(IdentityVault vault, {String? pin}) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('WindowsDpapiKeystore 仅能在 Windows 上使用');
    }
    await _file.parent.create(recursive: true);

    final dek = _randomBytes(_dekLen);
    final nonce = _randomBytes(_nonceLen);
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(vault.toJson())));
    final cipherText = _encryptGcm(dek, nonce, clear);
    final protectedDek = _Dpapi.protect(
      dek,
      description: 'PH01 子体身份 vault',
      entropy: utf8.encode(_dpapiEntropy),
      promptOnUnprotect: promptOnRead,
    );

    final payload = {
      'schema': _vaultSchema,
      'protection': 'windows_dpapi_user',
      'dek': base64Encode(protectedDek),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(cipherText),
    };
    await _file.writeAsString(jsonEncode(payload), flush: true);
  }

  @override
  Future<IdentityVault> readVault({String? pin}) async {
    if (await _file.exists()) {
      final raw =
          jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final schema = (raw['schema'] as num?)?.toInt() ?? 0;
      if (schema != _vaultSchema) {
        throw StateError('不支持的 DPAPI vault schema：$schema');
      }
      final dek = _Dpapi.unprotect(
        base64Decode(raw['dek'] as String),
        entropy: utf8.encode(_dpapiEntropy),
        prompt: promptOnRead ? '解锁 PH01 子体身份 vault' : null,
      );
      final nonce = base64Decode(raw['nonce'] as String);
      final cipherText = base64Decode(raw['ciphertext'] as String);
      final clear = _decryptGcm(dek, nonce, cipherText);
      return IdentityVault.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    }

    // 兼容旧的 PIN 文件；没有 PIN 时不自动迁移。
    if (await _legacyFile.exists()) {
      if (pin == null || pin.isEmpty) {
        throw const KeystoreAccessDeniedException(
          '旧版 PIN keystore 需要 PIN 才能迁移',
        );
      }
      return FileSecureKeystore(hanaHome: hanaHome).readVault(pin: pin);
    }
    throw StateError('身份 vault 不存在：${_file.path}');
  }

  @override
  Future<void> deleteAll() async {
    if (await _file.exists()) {
      await _file.delete();
    }
    if (await _legacyFile.exists()) {
      await _legacyFile.delete();
    }
  }
}

/// PIN 文件 fallback：只用于非 Windows / 测试 / 旧版本迁移。
class FileSecureKeystore extends SecureKeystore {
  FileSecureKeystore({required this.hanaHome});

  final Directory hanaHome;

  File get _file => File(p.join(hanaHome.path, 'identity', 'keystore.bin'));

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<void> writeVault(IdentityVault vault, {String? pin}) async {
    if (pin == null || pin.trim().length < 4) {
      throw ArgumentError('文件 fallback keystore 需要至少 4 位 PIN');
    }
    await _file.parent.create(recursive: true);

    final salt = _randomBytes(_pbkdf2SaltLen);
    final key = _deriveKey(pin: pin, salt: salt);
    final nonce = _randomBytes(_nonceLen);
    final clear = Uint8List.fromList(utf8.encode(jsonEncode(vault.toJson())));
    final cipherText = _encryptGcm(key, nonce, clear);

    final out = BytesBuilder()
      ..addByte(_pbkdf2SaltLen)
      ..add(salt)
      ..addByte(_nonceLen)
      ..add(nonce)
      ..add(cipherText);
    await _file.writeAsBytes(out.toBytes(), flush: true);
    await _maybeChmod600(_file);
  }

  @override
  Future<IdentityVault> readVault({String? pin}) async {
    if (pin == null || pin.isEmpty) {
      throw ArgumentError('文件 fallback keystore 需要 PIN');
    }
    if (!await _file.exists()) {
      throw StateError('密钥库不存在：${_file.path}');
    }
    final raw = await _file.readAsBytes();
    if (raw.length < 2 + _pbkdf2SaltLen + _nonceLen + _tagLen) {
      throw StateError('密钥库文件损坏：长度不足');
    }
    var offset = 0;
    final saltLen = raw[offset++];
    if (saltLen != _pbkdf2SaltLen) {
      throw StateError('密钥库 salt 长度不一致：$saltLen');
    }
    final salt = Uint8List.fromList(raw.sublist(offset, offset + saltLen));
    offset += saltLen;
    final nonceLen = raw[offset++];
    if (nonceLen != _nonceLen) {
      throw StateError('密钥库 nonce 长度不一致：$nonceLen');
    }
    final nonce = Uint8List.fromList(raw.sublist(offset, offset + nonceLen));
    offset += nonceLen;
    final cipherText = Uint8List.fromList(raw.sublist(offset));

    final key = _deriveKey(pin: pin, salt: salt);
    try {
      final clear = _decryptGcm(key, nonce, cipherText);
      if (clear.length == 32) {
        return IdentityVault(privateKey: clear);
      }
      return IdentityVault.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>,
      );
    } on InvalidCipherTextException {
      throw const InvalidPinException();
    } on FormatException {
      throw StateError('密钥库文件损坏：明文不是合法 vault JSON');
    }
  }

  @override
  Future<void> deleteAll() async {
    if (await _file.exists()) {
      await _file.delete();
    }
  }

  Uint8List _deriveKey({required String pin, required Uint8List salt}) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iter, 32));
    return pbkdf2.process(utf8.encode(pin));
  }

  Future<void> _maybeChmod600(File f) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', f.path]);
    } catch (_) {}
  }
}

Uint8List _encryptGcm(Uint8List key, Uint8List nonce, Uint8List clear) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(key), _tagLen * 8, nonce, Uint8List(0)),
    );
  return cipher.process(clear);
}

Uint8List _decryptGcm(Uint8List key, Uint8List nonce, Uint8List cipherText) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(KeyParameter(key), _tagLen * 8, nonce, Uint8List(0)),
    );
  return cipher.process(cipherText);
}

Uint8List _randomBytes(int n) {
  final rng = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

String _hexEncode(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(chars[(b >> 4) & 0x0f]);
    buf.write(chars[b & 0x0f]);
  }
  return buf.toString();
}

Uint8List _hexDecode(String hex) {
  final s = hex.trim();
  if (s.length.isOdd) {
    throw FormatException('hex 长度必须为偶数：${s.length}');
  }
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

final class _DataBlob extends ffi.Struct {
  @ffi.Uint32()
  external int cbData;

  external ffi.Pointer<ffi.Uint8> pbData;
}

final class _PromptStruct extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;

  @ffi.Uint32()
  external int dwPromptFlags;

  @ffi.IntPtr()
  external int hwndApp;

  external ffi.Pointer<Utf16> szPrompt;
}

typedef _CryptProtectDataNative =
    ffi.Int32 Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<Utf16>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<_PromptStruct>,
      ffi.Uint32,
      ffi.Pointer<_DataBlob>,
    );
typedef _CryptProtectDataDart =
    int Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<Utf16>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<_PromptStruct>,
      int,
      ffi.Pointer<_DataBlob>,
    );

typedef _CryptUnprotectDataNative =
    ffi.Int32 Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Pointer<Utf16>>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<_PromptStruct>,
      ffi.Uint32,
      ffi.Pointer<_DataBlob>,
    );
typedef _CryptUnprotectDataDart =
    int Function(
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Pointer<Utf16>>,
      ffi.Pointer<_DataBlob>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<_PromptStruct>,
      int,
      ffi.Pointer<_DataBlob>,
    );

typedef _LocalFreeNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _LocalFreeDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _GetLastErrorNative = ffi.Uint32 Function();
typedef _GetLastErrorDart = int Function();

class _Dpapi {
  static const int _promptOnUnprotect = 0x2;

  static Uint8List protect(
    Uint8List data, {
    required String description,
    required List<int> entropy,
    required bool promptOnUnprotect,
  }) {
    final api = _DpapiApi.instance;
    return _withBlob(data, (inBlob) {
      return _withBlob(Uint8List.fromList(entropy), (entropyBlob) {
        final outBlob = calloc<_DataBlob>();
        final descr = description.toNativeUtf16();
        ffi.Pointer<Utf16>? promptText;
        final promptStruct = promptOnUnprotect
            ? calloc<_PromptStruct>()
            : ffi.nullptr;
        try {
          if (promptOnUnprotect) {
            promptText = '解锁 PH01 子体身份 vault'.toNativeUtf16();
            promptStruct.ref
              ..cbSize = ffi.sizeOf<_PromptStruct>()
              ..dwPromptFlags = _promptOnUnprotect
              ..hwndApp = 0
              ..szPrompt = promptText;
          }
          final ok = api.cryptProtectData(
            inBlob,
            descr,
            entropyBlob,
            ffi.nullptr,
            promptStruct,
            0,
            outBlob,
          );
          if (ok == 0) {
            throw _DpapiException('CryptProtectData', api.lastError());
          }
          return _copyAndFreeOutput(outBlob, api);
        } finally {
          if (promptOnUnprotect) {
            calloc.free(promptStruct);
          }
          if (promptText != null) calloc.free(promptText);
          calloc.free(descr);
          calloc.free(outBlob);
        }
      });
    });
  }

  static Uint8List unprotect(
    Uint8List protectedData, {
    required List<int> entropy,
    String? prompt,
  }) {
    final api = _DpapiApi.instance;
    return _withBlob(protectedData, (inBlob) {
      return _withBlob(Uint8List.fromList(entropy), (entropyBlob) {
        final outBlob = calloc<_DataBlob>();
        final descrOut = calloc<ffi.Pointer<Utf16>>();
        final promptStruct = prompt == null
            ? ffi.nullptr
            : calloc<_PromptStruct>();
        ffi.Pointer<Utf16>? promptText;
        try {
          if (prompt != null) {
            promptText = prompt.toNativeUtf16();
            promptStruct.ref
              ..cbSize = ffi.sizeOf<_PromptStruct>()
              ..dwPromptFlags = _promptOnUnprotect
              ..hwndApp = 0
              ..szPrompt = promptText;
          }
          final ok = api.cryptUnprotectData(
            inBlob,
            descrOut,
            entropyBlob,
            ffi.nullptr,
            promptStruct,
            0,
            outBlob,
          );
          if (ok == 0) {
            final code = api.lastError();
            if (code == 1223) {
              throw const KeystoreAccessDeniedException('用户取消了 Windows 身份验证');
            }
            throw _DpapiException('CryptUnprotectData', code);
          }
          return _copyAndFreeOutput(outBlob, api);
        } finally {
          if (promptText != null) calloc.free(promptText);
          if (prompt != null) calloc.free(promptStruct);
          if (descrOut.value != ffi.nullptr) {
            api.localFree(descrOut.value.cast());
          }
          calloc.free(descrOut);
          calloc.free(outBlob);
        }
      });
    });
  }

  static T _withBlob<T>(Uint8List data, T Function(ffi.Pointer<_DataBlob>) fn) {
    final bytes = calloc<ffi.Uint8>(data.length);
    final blob = calloc<_DataBlob>();
    try {
      bytes.asTypedList(data.length).setAll(0, data);
      blob.ref
        ..cbData = data.length
        ..pbData = bytes;
      return fn(blob);
    } finally {
      calloc.free(blob);
      calloc.free(bytes);
    }
  }

  static Uint8List _copyAndFreeOutput(
    ffi.Pointer<_DataBlob> outBlob,
    _DpapiApi api,
  ) {
    final ptr = outBlob.ref.pbData;
    final len = outBlob.ref.cbData;
    if (ptr == ffi.nullptr || len <= 0) {
      return Uint8List(0);
    }
    try {
      return Uint8List.fromList(ptr.asTypedList(len));
    } finally {
      api.localFree(ptr.cast());
      outBlob.ref
        ..pbData = ffi.nullptr
        ..cbData = 0;
    }
  }
}

class _DpapiApi {
  _DpapiApi._()
    : _crypt32 = ffi.DynamicLibrary.open('crypt32.dll'),
      _kernel32 = ffi.DynamicLibrary.open('kernel32.dll') {
    cryptProtectData = _crypt32
        .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
          'CryptProtectData',
        );
    cryptUnprotectData = _crypt32
        .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
          'CryptUnprotectData',
        );
    localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>(
      'LocalFree',
    );
    lastError = _kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  }

  static final _DpapiApi instance = _DpapiApi._();

  final ffi.DynamicLibrary _crypt32;
  final ffi.DynamicLibrary _kernel32;
  late final _CryptProtectDataDart cryptProtectData;
  late final _CryptUnprotectDataDart cryptUnprotectData;
  late final _LocalFreeDart localFree;
  late final _GetLastErrorDart lastError;
}

class _DpapiException implements Exception {
  _DpapiException(this.operation, this.code);
  final String operation;
  final int code;

  @override
  String toString() => '$operation failed, GetLastError=$code';
}
