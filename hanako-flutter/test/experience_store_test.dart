import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/experience/experience.dart';
import 'package:hanako/identity/keypair.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late HanakoKeyPair keyPair;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hanako_experience_store_');
    keyPair = HanakoKeyPair.generate();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('保存本地经验时只写入可读文件树与 metadata', () async {
    final store = ExperienceStore(agentDir: tmp);

    final result = await store.savePrivateExperience(
      title: '登录身份讨论',
      brief: '身份恢复流程原始讨论',
      keywords: ['identity', 'login', 'identity'],
      conversation:
          '[2026-05-09T00:00:00Z] 用户: needle 登录失败\n'
          '[2026-05-09T00:00:01Z] 助手: 继续检查日志\n',
      events: '[2026-05-09T00:00:02Z] 工具: grep needle\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );

    expect(Directory(result.path).existsSync(), true);
    expect(
      File(p.join(result.contentPath, 'raw', 'conversation.md')).existsSync(),
      true,
    );
    expect(
      Directory(p.join(result.contentPath, 'attachments')).existsSync(),
      true,
    );
    expect(File(result.metadataPath).existsSync(), true);
    expect(File(p.join(result.path, 'publisher.json')).existsSync(), false);

    final listed = await store.list(scope: ExperienceScope.private);
    expect(listed.single.metadata?.title, '登录身份讨论');
    expect(listed.single.metadata?.keywords, ['identity', 'login']);
  });

  test('用户授权发布流程可为本地经验生成 .hxp 外层结构', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '登录身份讨论',
      conversation: '[2026-05-09T00:00:00Z] 用户: needle 登录失败\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );

    final result = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );

    expect(File(result.packagePath).existsSync(), true);
    expect(File(result.publisherPath).existsSync(), true);
    expect(File(result.ratingsPath).existsSync(), true);
    expect(File(result.cachePath).existsSync(), true);

    final outer = ZipDecoder().decodeBytes(
      File(result.cachePath).readAsBytesSync(),
    );
    expect(outer.findFile('package.zip'), isNotNull);
    expect(outer.findFile('publisher.json'), isNotNull);
    expect(outer.findFile('ratings.dat'), isNotNull);
  });

  test('提审后本地列表会保留待审状态用于禁止重复提交', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '待审状态测试',
      conversation: '原始内容\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );

    await store.recordReviewSubmission(
      experienceId: saved.experienceId,
      remoteExperienceId: 'remote_${saved.experienceId}',
      status: 'inbox',
      packageBytesSha256: 'a' * 64,
      packageHash: 'b' * 64,
      reviewReason: 'pending',
      submittedAt: DateTime.utc(2026, 5, 9, 2, 0, 0),
    );

    final item = (await store.list(scope: ExperienceScope.private)).single;
    expect(item.reviewState, isNotNull);
    expect(item.reviewState!.pendingReview, true);
    expect(item.reviewState!.submitted, true);
    expect(
      item.reviewState!.remoteExperienceId,
      'remote_${saved.experienceId}',
    );
    expect(item.reviewState!.displayLabel, '已提交，等待审核');
  });

  test('提审打包不会用程序规则脱敏内容', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '脱敏策略测试',
      conversation: '联系邮箱 user@example.com，手机号 13800138000\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );

    final result = await store.packagePrivateExperienceForReview(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final outer = ZipDecoder().decodeBytes(result.packageBytes);
    final inner = ZipDecoder().decodeBytes(
      outer.findFile('package.zip')!.content,
    );
    final conversation = utf8.decode(
      inner.findFile('raw/conversation.md')!.content,
    );

    expect(conversation, contains('user@example.com'));
    expect(conversation, contains('13800138000'));
    expect(conversation, isNot(contains('REDACTED')));
    expect(
      result.packageBytesSha256,
      sha256.convert(result.packageBytes).toString(),
    );
    expect(result.packageHash, result.publisher.packageHash);
    expect(result.packageBytesSha256, isNot(result.packageHash));
  });

  test('publisher.json 验签通过，篡改 package.zip 后失败', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '签名测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 原始内容\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final result = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );

    final publisher = ExperiencePublisher.fromJson(
      jsonDecode(File(result.publisherPath).readAsStringSync())
          as Map<String, dynamic>,
    );
    final packageBytes = File(result.packagePath).readAsBytesSync();
    expect(publisher.verifyPackage(packageBytes).ok, true);

    final tampered = _tamperPackageZip(packageBytes);
    expect(publisher.verifyPackage(tampered).ok, false);
  });

  test('导入网络包后只通过搜索返回路径、行号和片段', () async {
    final source = ExperienceStore(
      agentDir: Directory(p.join(tmp.path, 'source')),
    );
    final saved = await source.savePrivateExperience(
      title: '网络导入测试',
      conversation:
          '[2026-05-09T00:00:00Z] 用户: needle 命中行\n'
          '[2026-05-09T00:00:01Z] 助手: 上下文仍在文件中\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await source.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);

    final target = ExperienceStore(
      agentDir: Directory(p.join(tmp.path, 'target')),
    );
    final imported = await target.importNetworkPackage(
      _withReviewMaterials(
        File(generated.cachePath).readAsBytesSync(),
        review.materials,
      ),
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );

    expect(imported.ok, true);
    expect(File(imported.cachePath!).existsSync(), true);
    expect(
      File(
        p.join(imported.path!, 'content', 'raw', 'conversation.md'),
      ).existsSync(),
      true,
    );

    final results = await target.search(
      'needle',
      scopes: {ExperienceScope.network},
    );
    expect(results, hasLength(1));
    expect(results.single.experienceId, saved.experienceId);
    expect(results.single.relativePath, 'content/raw/conversation.md');
    expect(results.single.line, 1);
    expect(
      results.single.toJson().keys,
      containsAll(['path', 'line', 'snippet']),
    );
    expect(results.single.toJson().containsKey('content'), false);
  });

  test('缺少审核签名材料的包拒绝作为网络经验导入', () async {
    final source = ExperienceStore(
      agentDir: Directory(p.join(tmp.path, 'source')),
    );
    final saved = await source.savePrivateExperience(
      title: '未审核导入测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 原始内容\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await source.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );

    final target = ExperienceStore(
      agentDir: Directory(p.join(tmp.path, 'target')),
    );
    final imported = await target.importNetworkPackage(
      File(generated.cachePath).readAsBytesSync(),
    );

    expect(imported.ok, false);
    expect(imported.message, contains('审核签名'));
    expect(await target.list(scope: ExperienceScope.network), isEmpty);
  });

  test('原作者可只取回审核材料并附加到本地包', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '只取签名测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 本地包完整\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);

    final attached = await store.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );

    expect(attached.ok, true);
    expect(File(attached.reviewMaterialsPath!).existsSync(), true);
    final imported =
        await ExperienceStore(
          agentDir: Directory(p.join(tmp.path, 'target')),
        ).importNetworkPackage(
          File(attached.cachePath!).readAsBytesSync(),
          trustAnchor: review.anchor,
          now: DateTime.utc(2026, 5, 9),
        );
    expect(imported.ok, true);
  });

  test('供给方工作流会从完整本地包构建 offer', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '供给方构建测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 本地内容\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);
    await store.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );

    final workflow = ExperiencePackageSupplyWorkflow(
      store: store,
      dhtClient: ExperienceDhtHttpClient(dhtBaseUrl: 'https://dht.test/'),
    );
    final offer = await workflow.buildLocalPackageOffer(
      experienceId: saved.experienceId,
      requestId: 'req_1',
      providerPeerId: 'peer_provider',
      providerAddrs: const [
        ExperienceNetworkEndpoint(
          network: 'udp',
          host: '198.51.100.20',
          port: 41020,
        ),
      ],
      availableTransports: const [
        ExperienceTransport.ipv4HolePunch,
        ExperienceTransport.dhtRelay,
      ],
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9, 9, 0, 0),
    );

    expect(offer.requestId, 'req_1');
    expect(offer.experienceId, saved.experienceId);
    expect(offer.packageHash, generated.publisher.packageHash);
    expect(offer.providerPeerId, 'peer_provider');
    expect(offer.providerAddrs.single.host, '198.51.100.20');
    expect(offer.reviewMaterials?.rootKeyId, 'test-root');
    expect(offer.publisher['experience_id'], saved.experienceId);
    expect(offer.availableTransports, [
      ExperienceTransport.ipv4HolePunch,
      ExperienceTransport.dhtRelay,
    ]);
  });

  test('供给方工作流拒绝未附审核材料的本地包', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '供给方拒绝测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 本地内容\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );

    final workflow = ExperiencePackageSupplyWorkflow(
      store: store,
      dhtClient: ExperienceDhtHttpClient(dhtBaseUrl: 'https://dht.test/'),
    );

    await expectLater(
      workflow.buildLocalPackageOffer(
        experienceId: saved.experienceId,
        requestId: 'req_1',
        providerPeerId: 'peer_provider',
        now: DateTime.utc(2026, 5, 9, 9, 0, 0),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('审核签名材料'),
        ),
      ),
    );
  });

  test('本地包损坏时可用管理端完整包覆盖本地副本', () async {
    final store = ExperienceStore(agentDir: tmp);
    final saved = await store.savePrivateExperience(
      title: '完整包覆盖测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: original needle\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await store.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);
    final reviewedPackage = _withReviewMaterials(
      File(generated.cachePath).readAsBytesSync(),
      review.materials,
    );

    await File(
      generated.cachePath,
    ).writeAsBytes(_tamperOuterPackage(reviewedPackage), flush: true);
    final attached = await store.attachReviewMaterialsToPrivatePackage(
      experienceId: saved.experienceId,
      reviewMaterials: review.materials,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );
    expect(attached.ok, false);
    expect(attached.needsFullPackage, true);

    final replaced = await store.replacePrivatePackageFromNetworkPackage(
      reviewedPackage,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );
    expect(replaced.ok, true);
    final restored = File(
      p.join(
        tmp.path,
        'experience',
        'private',
        saved.experienceId,
        'content',
        'raw',
        'conversation.md',
      ),
    ).readAsStringSync();
    expect(restored, contains('original needle'));
  });

  test('篡改的网络包拒绝入库但保留错误信息', () async {
    final source = ExperienceStore(
      agentDir: Directory(p.join(tmp.path, 'source')),
    );
    final saved = await source.savePrivateExperience(
      title: '篡改导入测试',
      conversation: '[2026-05-09T00:00:00Z] 用户: 原始内容\n',
      now: DateTime.utc(2026, 5, 9, 1, 2, 3),
    );
    final generated = await source.packagePrivateExperience(
      experienceId: saved.experienceId,
      keyPair: keyPair,
    );
    final review = _reviewFixture(generated.publisher);

    final tampered = _tamperOuterPackage(
      _withReviewMaterials(
        File(generated.cachePath).readAsBytesSync(),
        review.materials,
      ),
    );
    final target = ExperienceStore(
      agentDir: Directory(p.join(tmp.path, 'target')),
    );
    final imported = await target.importNetworkPackage(
      tampered,
      trustAnchor: review.anchor,
      now: DateTime.utc(2026, 5, 9),
    );

    expect(imported.ok, false);
    expect(imported.message, contains('hash'));
    expect(await target.list(scope: ExperienceScope.network), isEmpty);
  });
}

class _ReviewFixture {
  const _ReviewFixture(this.materials, this.anchor);
  final ExperienceReviewMaterials materials;
  final ExperienceReviewTrustAnchor anchor;
}

_ReviewFixture _reviewFixture(ExperiencePublisher publisher) {
  final root = HanakoKeyPair.generate();
  final master = HanakoKeyPair.generate();
  const rootKeyId = 'test-root';
  const algorithm = ExperiencePublisher.algorithm;
  final certPayload = <String, dynamic>{
    'schema_version': 'ph01.experience.master_certificate.v1',
    'certificate_id': 'test-master',
    'role': 'experience_review_master',
    'issuer_root_key_id': rootKeyId,
    'algorithm': algorithm,
    'public_key_hex': master.publicKeyHex,
    'not_before': '2026-05-01T00:00:00Z',
    'not_after': '2026-06-01T00:00:00Z',
    'extensions': {'revoked_certificate_fingerprints': <String>[]},
  };
  final certPayloadBytes = Uint8List.fromList(
    utf8.encode(jsonEncode(certPayload)),
  );
  final managerCertificate = <String, dynamic>{
    'certificate': certPayload,
    'signature_algorithm': algorithm,
    'signature_payload_sha256': _sha256Hex(certPayloadBytes),
    'root_signature_hex': _hexEncode(root.sign(certPayloadBytes)),
  };
  final signaturePayload = <String, dynamic>{
    'schema_version': 'ph01.experience.review_payload.v1',
    'experience_id': publisher.experienceId,
    'package_hash_algorithm': 'sha256',
    'package_hash': publisher.packageHash,
    'publisher_pubkey': publisher.publisherPubkey,
    'review_status': 'network',
    'review_mode': 'manual_review',
    'reviewed_at': '2026-05-09T00:00:00Z',
    'certificate_id': 'test-master',
    'signer_role': 'experience_review_master',
    'signature_algorithm': algorithm,
  };
  final payloadBytes = Uint8List.fromList(
    utf8.encode(jsonEncode(signaturePayload)),
  );
  return _ReviewFixture(
    ExperienceReviewMaterials(
      rootKeyId: rootKeyId,
      signatureAlgorithm: algorithm,
      signaturePayloadSha256: _sha256Hex(payloadBytes),
      managerReviewSignature: _hexEncode(master.sign(payloadBytes)),
      signaturePayload: signaturePayload,
      managerCertificate: managerCertificate,
    ),
    ExperienceReviewTrustAnchor(
      rootKeyId: rootKeyId,
      algorithm: algorithm,
      rootPublicKeyHex: root.publicKeyHex,
    ),
  );
}

Uint8List _withReviewMaterials(
  Uint8List hxpBytes,
  ExperienceReviewMaterials materials,
) {
  final outer = ZipDecoder().decodeBytes(hxpBytes);
  final archive = Archive()
    ..add(
      ArchiveFile.bytes('package.zip', outer.findFile('package.zip')!.content),
    )
    ..add(
      ArchiveFile.bytes(
        'publisher.json',
        outer.findFile('publisher.json')!.content,
      ),
    )
    ..add(
      ArchiveFile.bytes('ratings.dat', outer.findFile('ratings.dat')!.content),
    )
    ..add(
      ArchiveFile.string(
        'review-materials.json',
        const JsonEncoder.withIndent('  ').convert(materials.toJson()),
      ),
    );
  return ZipEncoder().encodeBytes(archive, autoClose: false);
}

Uint8List _tamperOuterPackage(Uint8List hxpBytes) {
  final outer = ZipDecoder().decodeBytes(hxpBytes);
  final packageBytes = outer.findFile('package.zip')!.content;
  final publisherBytes = outer.findFile('publisher.json')!.content;
  final ratingsBytes = outer.findFile('ratings.dat')!.content;
  final tamperedPackage = _tamperPackageZip(packageBytes);
  final archive = Archive()
    ..add(ArchiveFile.bytes('package.zip', tamperedPackage))
    ..add(ArchiveFile.bytes('publisher.json', publisherBytes))
    ..add(ArchiveFile.bytes('ratings.dat', ratingsBytes));
  return ZipEncoder().encodeBytes(archive, autoClose: false);
}

Uint8List _tamperPackageZip(Uint8List packageBytes) {
  final inner = ZipDecoder().decodeBytes(packageBytes);
  final archive = Archive();
  for (final file in inner.files) {
    if (file.isDirectory) {
      archive.add(ArchiveFile.directory(file.name));
      continue;
    }
    if (file.name == 'raw/conversation.md') {
      archive.add(ArchiveFile.string(file.name, 'tampered\n'));
    } else {
      archive.add(ArchiveFile.bytes(file.name, file.content));
    }
  }
  return ZipEncoder().encodeBytes(archive, autoClose: false);
}

String _sha256Hex(List<int> bytes) => sha256
    .convert(bytes)
    .bytes
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

String _hexEncode(Uint8List bytes) {
  const chars = '0123456789abcdef';
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer
      ..write(chars[(byte >> 4) & 0x0f])
      ..write(chars[byte & 0x0f]);
  }
  return buffer.toString();
}
