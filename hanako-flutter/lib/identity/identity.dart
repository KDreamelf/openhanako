// lib/identity/identity.dart
//
// Identity 模块对外门面：UI 层 / 启动入口只依赖本文件即可。
//
// 子模块职责：
//   - keypair.dart                  ECDSA secp256k1 密钥对原语
//   - mnemonic.dart                 BIP-39 中文变体（12 词 ↔ 私钥）
//   - word_dict.dart                2048 中文名词字典（v1.0-rc3）
//   - story_composer.dart           故事编排（12 词 → 50 字小故事）
//   - story_parser.dart             故事解析（模糊故事 → 矩阵）
//   - recovery.dart                 矩阵搜索 + Isolate 并行
//   - recovery_accelerator.dart     原生/异构恢复加速后端协议
//   - secure_keystore.dart          私钥本地加密存储
//   - identity_repository.dart      业务封装
//   - ecdh.dart                     ECDH + AES-256-GCM 会话加解密
//   - signed_request.dart           SignedRequest 包装
//   - hanako_backend_client.dart    与 ph01-backend 三方通信
//   - experience_trust_anchor.dart  经验网络根信任锚

export 'keypair.dart';
export 'mnemonic.dart';
export 'word_dict.dart';
export 'story_composer.dart';
export 'story_parser.dart';
export 'recovery.dart';
export 'recovery_accelerator.dart';
export 'windows_recovery_accelerator.dart';
export 'secure_keystore.dart';
export 'identity_repository.dart';
export 'ecdh.dart';
export 'signed_request.dart';
export 'hanako_backend_client.dart';
export 'experience_trust_anchor.dart';
