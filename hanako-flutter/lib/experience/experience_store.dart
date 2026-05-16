import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../identity/keypair.dart';
import 'experience_network.dart';
import 'experience_review.dart';

class ExperienceStore {
  ExperienceStore({required Directory agentDir}) : _agentDir = agentDir;

  final Directory _agentDir;

  Directory get rootDir => Directory(p.join(_agentDir.path, 'experience'));
  Directory get privateDir => Directory(p.join(rootDir.path, 'private'));
  Directory get networkDir => Directory(p.join(rootDir.path, 'network'));
  Directory get cacheDir => Directory(p.join(rootDir.path, 'cache'));

  Future<void> init() async {
    await privateDir.create(recursive: true);
    await networkDir.create(recursive: true);
    await cacheDir.create(recursive: true);
  }

  Future<ExperienceSaveResult> savePrivateExperience({
    required String title,
    required String conversation,
    String brief = '',
    List<String> keywords = const [],
    String events = '',
    String sourceType = '',
    String sourceSessionPath = '',
    List<ExperienceRawFile> toolFiles = const [],
    List<ExperienceRawFile> attachmentFiles = const [],
    DateTime? now,
  }) async {
    await init();
    final createdAt = (now ?? DateTime.now().toUtc()).toUtc();
    final id = _newExperienceId(title, createdAt);
    final itemDir = _safeChild(privateDir, id);
    if (await itemDir.exists()) {
      throw StateError('经验 ID 已存在：$id');
    }
    final contentDir = Directory(p.join(itemDir.path, 'content'));
    await _writeRawDump(
      contentDir: contentDir,
      metadata: ExperienceMetadata(
        experienceId: id,
        title: title.trim(),
        brief: brief.trim(),
        keywords: _normalizeKeywords(keywords),
        createdAt: createdAt.toIso8601String(),
        sourceType: sourceType.trim(),
        sourceSessionPath: sourceSessionPath.trim(),
      ),
      conversation: conversation,
      events: events,
      toolFiles: toolFiles,
      attachmentFiles: attachmentFiles,
    );
    return ExperienceSaveResult(
      experienceId: id,
      scope: ExperienceScope.private,
      path: itemDir.path,
      contentPath: contentDir.path,
      metadataPath: p.join(contentDir.path, 'metadata.json'),
      metadata: ExperienceMetadata(
        experienceId: id,
        title: title.trim(),
        brief: brief.trim(),
        keywords: _normalizeKeywords(keywords),
        createdAt: createdAt.toIso8601String(),
        sourceType: sourceType.trim(),
        sourceSessionPath: sourceSessionPath.trim(),
      ),
    );
  }

  Future<ExperienceSaveResult> overwritePrivateExperience({
    required String experienceId,
    required String title,
    required String conversation,
    String brief = '',
    List<String> keywords = const [],
    String events = '',
    String sourceType = '',
    String sourceSessionPath = '',
    List<ExperienceRawFile> toolFiles = const [],
    List<ExperienceRawFile> attachmentFiles = const [],
    DateTime? now,
  }) async {
    await init();
    _validateExperienceId(experienceId);
    final itemDir = _safeChild(privateDir, experienceId);
    if (!await itemDir.exists()) {
      throw StateError('本地私有经验不存在：$experienceId');
    }
    if (await privateExperienceHasReviewMaterials(experienceId: experienceId)) {
      throw StateError('经验已附加审核材料，不能直接覆盖内容');
    }
    await _deletePrivatePackageArtifacts(experienceId, itemDir);
    final contentDir = Directory(p.join(itemDir.path, 'content'));
    if (await contentDir.exists()) {
      await contentDir.delete(recursive: true);
    }
    final createdAt = (now ?? DateTime.now().toUtc()).toUtc();
    final metadata = ExperienceMetadata(
      experienceId: experienceId,
      title: title.trim(),
      brief: brief.trim(),
      keywords: _normalizeKeywords(keywords),
      createdAt: createdAt.toIso8601String(),
      sourceType: sourceType.trim(),
      sourceSessionPath: sourceSessionPath.trim(),
    );
    await _writeRawDump(
      contentDir: contentDir,
      metadata: metadata,
      conversation: conversation,
      events: events,
      toolFiles: toolFiles,
      attachmentFiles: attachmentFiles,
    );
    return ExperienceSaveResult(
      experienceId: experienceId,
      scope: ExperienceScope.private,
      path: itemDir.path,
      contentPath: contentDir.path,
      metadataPath: p.join(contentDir.path, 'metadata.json'),
      metadata: metadata,
    );
  }

  Future<bool> privateExperienceHasReviewMaterials({
    required String experienceId,
  }) async {
    await init();
    _validateExperienceId(experienceId);
    final itemDir = _safeChild(privateDir, experienceId);
    return File(p.join(itemDir.path, 'review-materials.json')).exists();
  }

  Future<void> recordReviewSubmission({
    required String experienceId,
    required String remoteExperienceId,
    required String status,
    required String packageBytesSha256,
    required String packageHash,
    String reviewReason = '',
    DateTime? submittedAt,
  }) async {
    await init();
    _validateExperienceId(experienceId);
    final itemDir = _safeChild(privateDir, experienceId);
    if (!await itemDir.exists()) {
      throw StateError('本地私有经验不存在：$experienceId');
    }
    final now = (submittedAt ?? DateTime.now().toUtc()).toUtc();
    await _writeReviewState(
      itemDir,
      ExperienceReviewState(
        experienceId: experienceId,
        remoteExperienceId: remoteExperienceId.trim().isEmpty
            ? experienceId
            : remoteExperienceId.trim(),
        status: _normalizeReviewStateStatus(status),
        submittedAt: now.toIso8601String(),
        updatedAt: now.toIso8601String(),
        packageBytesSha256: packageBytesSha256.trim().toLowerCase(),
        packageHash: packageHash.trim().toLowerCase(),
        reviewReason: reviewReason.trim(),
      ),
    );
  }

  Future<ExperienceSaveResult> importRawDirectoryToPrivate({
    required Directory rawDir,
    DateTime? now,
  }) async {
    await init();
    final packageBytes = await _packDirectory(rawDir);
    final metadata = _metadataFromPackage(packageBytes);
    final effectiveMetadata = DateTime.tryParse(metadata.createdAt) == null
        ? ExperienceMetadata(
            experienceId: metadata.experienceId,
            title: metadata.title,
            brief: metadata.brief,
            keywords: metadata.keywords,
            createdAt: (now ?? DateTime.now().toUtc())
                .toUtc()
                .toIso8601String(),
          )
        : metadata;
    final id = metadata.experienceId.trim().isNotEmpty
        ? metadata.experienceId.trim()
        : _idFromPackageHash(packageBytes);
    _validateExperienceId(id);
    final itemDir = _safeChild(privateDir, id);
    if (await itemDir.exists()) {
      throw StateError('经验 ID 已存在：$id');
    }
    final contentDir = Directory(p.join(itemDir.path, 'content'));
    await _extractZip(packageBytes, contentDir);
    return ExperienceSaveResult(
      experienceId: id,
      scope: ExperienceScope.private,
      path: itemDir.path,
      contentPath: contentDir.path,
      metadataPath: p.join(contentDir.path, 'metadata.json'),
      metadata: effectiveMetadata,
    );
  }

  Future<ExperiencePackageResult> packagePrivateExperience({
    required String experienceId,
    required HanakoKeyPair keyPair,
    DateTime? now,
  }) async {
    await init();
    _validateExperienceId(experienceId);
    final itemDir = _safeChild(privateDir, experienceId);
    if (!await itemDir.exists()) {
      throw StateError('本地私有经验不存在：$experienceId');
    }
    final contentDir = Directory(p.join(itemDir.path, 'content'));
    if (!await contentDir.exists()) {
      throw StateError('本地经验缺少 content 文件树：$experienceId');
    }
    final metadata = await _tryReadMetadata(
      File(p.join(contentDir.path, 'metadata.json')),
    );
    final createdAt =
        DateTime.tryParse(metadata?.createdAt ?? '') ??
        (now ?? DateTime.now().toUtc()).toUtc();
    return _buildAndSave(
      id: experienceId,
      itemDir: itemDir,
      contentDir: contentDir,
      keyPair: keyPair,
      createdAt: createdAt,
      scope: ExperienceScope.private,
    );
  }

  Future<ExperienceImportResult> importNetworkPackage(
    Uint8List hxpBytes, {
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    await init();
    late final _OuterPackageInfo info;
    try {
      info = _readOuterPackage(hxpBytes);
    } catch (e) {
      return ExperienceImportResult.failed('经验包结构无效：$e');
    }
    final verification = _verifyReviewedOuterPackage(
      info,
      trustAnchor: trustAnchor,
      now: now,
    );
    if (!verification.ok) {
      return ExperienceImportResult.failed(verification.message);
    }
    final id = info.publisher.experienceId;
    _validateExperienceId(id);
    final itemDir = _safeChild(networkDir, id);
    if (await itemDir.exists()) {
      await itemDir.delete(recursive: true);
    }
    await itemDir.create(recursive: true);
    await File(
      p.join(itemDir.path, 'package.zip'),
    ).writeAsBytes(info.packageBytes, flush: true);
    await File(p.join(itemDir.path, 'publisher.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(info.publisher.toJson()),
      flush: true,
    );
    await File(
      p.join(itemDir.path, 'ratings.dat'),
    ).writeAsString(info.ratingsDat, flush: true);
    await File(p.join(itemDir.path, 'review-materials.json')).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(info.reviewMaterials!.toJson()),
      flush: true,
    );
    await _extractZip(
      info.packageBytes,
      Directory(p.join(itemDir.path, 'content')),
    );
    final cachePath = p.join(cacheDir.path, '$id.hxp');
    await File(cachePath).writeAsBytes(hxpBytes, flush: true);
    return ExperienceImportResult.success(
      experienceId: id,
      path: itemDir.path,
      cachePath: cachePath,
      packageHash: info.publisher.packageHash,
    );
  }

  Future<ExperienceReviewAttachResult> attachReviewMaterialsToPrivatePackage({
    required String experienceId,
    required ExperienceReviewMaterials reviewMaterials,
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    await init();
    _validateExperienceId(experienceId);
    final itemDir = _safeChild(privateDir, experienceId);
    final cacheFile = File(p.join(cacheDir.path, '$experienceId.hxp'));
    if (!await itemDir.exists() || !await cacheFile.exists()) {
      return ExperienceReviewAttachResult.failed('本地私有经验包不存在：$experienceId');
    }
    late final _OuterPackageInfo info;
    try {
      info = _readOuterPackage(await cacheFile.readAsBytes());
    } catch (e) {
      return ExperienceReviewAttachResult.failed('本地经验包结构无效：$e');
    }
    final publisherVerification = info.publisher.verifyPackage(
      info.packageBytes,
    );
    if (!publisherVerification.ok) {
      return ExperienceReviewAttachResult.incomplete(
        publisherVerification.message,
      );
    }
    final reviewVerification = reviewMaterials.verify(
      experienceId: info.publisher.experienceId,
      packageHash: info.publisher.packageHash,
      publisherPubkey: info.publisher.publisherPubkey,
      trustAnchor: trustAnchor,
      now: now,
    );
    if (!reviewVerification.ok) {
      return ExperienceReviewAttachResult.failed(reviewVerification.message);
    }
    final hxpBytes = _buildOuterPackage(
      packageBytes: info.packageBytes,
      publisher: info.publisher,
      ratingsDat: info.ratingsDat,
      reviewMaterials: reviewMaterials,
    );
    final reviewPath = p.join(itemDir.path, 'review-materials.json');
    await File(reviewPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(reviewMaterials.toJson()),
      flush: true,
    );
    await cacheFile.writeAsBytes(hxpBytes, flush: true);
    await _writeReviewState(
      itemDir,
      ExperienceReviewState(
        experienceId: experienceId,
        remoteExperienceId: info.publisher.experienceId,
        status: 'network',
        submittedAt: (await _tryReadReviewState(itemDir))?.submittedAt ?? '',
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        packageHash: info.publisher.packageHash,
        reviewReason: '审核材料已附加',
      ),
    );
    return ExperienceReviewAttachResult.success(
      experienceId: experienceId,
      cachePath: cacheFile.path,
      reviewMaterialsPath: reviewPath,
    );
  }

  Future<ExperienceReviewAttachResult> replacePrivatePackageFromNetworkPackage(
    Uint8List hxpBytes, {
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    await init();
    late final _OuterPackageInfo info;
    try {
      info = _readOuterPackage(hxpBytes);
    } catch (e) {
      return ExperienceReviewAttachResult.failed('完整经验包结构无效：$e');
    }
    final verification = _verifyReviewedOuterPackage(
      info,
      trustAnchor: trustAnchor,
      now: now,
    );
    if (!verification.ok) {
      return ExperienceReviewAttachResult.failed(verification.message);
    }
    final id = info.publisher.experienceId;
    _validateExperienceId(id);
    final itemDir = _safeChild(privateDir, id);
    if (await itemDir.exists()) {
      await itemDir.delete(recursive: true);
    }
    await itemDir.create(recursive: true);
    await File(
      p.join(itemDir.path, 'package.zip'),
    ).writeAsBytes(info.packageBytes, flush: true);
    await File(p.join(itemDir.path, 'publisher.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(info.publisher.toJson()),
      flush: true,
    );
    await File(
      p.join(itemDir.path, 'ratings.dat'),
    ).writeAsString(info.ratingsDat, flush: true);
    final reviewPath = p.join(itemDir.path, 'review-materials.json');
    await File(reviewPath).writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(info.reviewMaterials!.toJson()),
      flush: true,
    );
    final contentDir = Directory(p.join(itemDir.path, 'content'));
    await _extractZip(info.packageBytes, contentDir);
    final cachePath = p.join(cacheDir.path, '$id.hxp');
    await File(cachePath).writeAsBytes(hxpBytes, flush: true);
    await _writeReviewState(
      itemDir,
      ExperienceReviewState(
        experienceId: id,
        remoteExperienceId: id,
        status: 'network',
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        packageHash: info.publisher.packageHash,
        reviewReason: '完整包已通过审核',
      ),
    );
    return ExperienceReviewAttachResult.success(
      experienceId: id,
      cachePath: cachePath,
      reviewMaterialsPath: reviewPath,
    );
  }

  Future<List<ExperienceSearchResult>> search(
    String query, {
    int maxResults = 50,
    Set<ExperienceScope> scopes = const {
      ExperienceScope.private,
      ExperienceScope.network,
    },
  }) async {
    await init();
    final text = query.trim();
    if (text.isEmpty) return const [];
    final queryLower = text.toLowerCase();
    final out = <ExperienceSearchResult>[];
    for (final scope in scopes) {
      final base = scope == ExperienceScope.private ? privateDir : networkDir;
      if (!await base.exists()) continue;
      final items = await base
          .list(followLinks: false)
          .where((entity) => entity is Directory)
          .cast<Directory>()
          .toList();
      items.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final item in items) {
        if (out.length >= maxResults) return out;
        final id = p.basename(item.path);
        final metadata = await _tryReadMetadata(
          File(p.join(item.path, 'content', 'metadata.json')),
        );
        final content = Directory(p.join(item.path, 'content'));
        if (!await content.exists()) continue;
        await for (final entity in content.list(
          recursive: true,
          followLinks: false,
        )) {
          if (out.length >= maxResults) return out;
          if (entity is! File) continue;
          if (!_isSearchableTextFile(entity.path)) continue;
          final stat = await entity.stat();
          if (stat.size > 1024 * 1024) continue;
          final rel = p
              .relative(entity.path, from: item.path)
              .split(p.separator)
              .join('/');
          final lines = await entity
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .toList()
              .catchError((_) => <String>[]);
          for (var i = 0; i < lines.length; i++) {
            final line = lines[i];
            final lower = line.toLowerCase();
            final idx = lower.indexOf(queryLower);
            if (idx < 0) continue;
            out.add(
              ExperienceSearchResult(
                experienceId: id,
                scope: scope,
                title: metadata?.title ?? id,
                filePath: entity.path,
                relativePath: rel,
                line: i + 1,
                snippet: _snippet(line, idx, queryLower.length),
                metadata: metadata,
              ),
            );
            if (out.length >= maxResults) return out;
          }
        }
      }
    }
    return out;
  }

  Future<List<ExperienceListItem>> list({ExperienceScope? scope}) async {
    await init();
    final scopes = scope == null ? ExperienceScope.values : [scope];
    final out = <ExperienceListItem>[];
    for (final currentScope in scopes) {
      final base = currentScope == ExperienceScope.private
          ? privateDir
          : networkDir;
      if (!await base.exists()) continue;
      await for (final entity in base.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final id = p.basename(entity.path);
        final metadata = await _tryReadMetadata(
          File(p.join(entity.path, 'content', 'metadata.json')),
        );
        out.add(
          ExperienceListItem(
            experienceId: id,
            scope: currentScope,
            title: metadata?.title ?? id,
            path: entity.path,
            metadata: metadata,
            reviewState: await _effectiveReviewState(
              entity,
              id: id,
              scope: currentScope,
            ),
          ),
        );
      }
    }
    out.sort((a, b) => a.experienceId.compareTo(b.experienceId));
    return out;
  }

  Future<ExperiencePackageResult> _buildAndSave({
    required String id,
    required Directory itemDir,
    required Directory contentDir,
    required HanakoKeyPair keyPair,
    required DateTime createdAt,
    required ExperienceScope scope,
    Uint8List? packageBytes,
  }) async {
    await itemDir.create(recursive: true);
    packageBytes ??= await _packDirectory(contentDir);
    final publisher = ExperiencePublisher.sign(
      experienceId: id,
      packageBytes: packageBytes,
      keyPair: keyPair,
      createdAt: createdAt,
    );
    final ratings = _initialRatingsDat(id, publisher.packageHash, createdAt);
    final hxpBytes = _buildOuterPackage(
      packageBytes: packageBytes,
      publisher: publisher,
      ratingsDat: ratings,
    );
    final packagePath = p.join(itemDir.path, 'package.zip');
    final publisherPath = p.join(itemDir.path, 'publisher.json');
    final ratingsPath = p.join(itemDir.path, 'ratings.dat');
    final cachePath = p.join(cacheDir.path, '$id.hxp');
    await File(packagePath).writeAsBytes(packageBytes, flush: true);
    await File(publisherPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(publisher.toJson()),
      flush: true,
    );
    await File(ratingsPath).writeAsString(ratings, flush: true);
    await File(cachePath).writeAsBytes(hxpBytes, flush: true);
    return ExperiencePackageResult(
      experienceId: id,
      scope: scope,
      path: itemDir.path,
      contentPath: contentDir.path,
      packagePath: packagePath,
      publisherPath: publisherPath,
      ratingsPath: ratingsPath,
      cachePath: cachePath,
      packageHash: publisher.packageHash,
      publisher: publisher,
    );
  }

  Future<ExperienceSubmissionPackageResult> packagePrivateExperienceForReview({
    required String experienceId,
    required HanakoKeyPair keyPair,
    DateTime? now,
  }) async {
    final packaged = await packagePrivateExperience(
      experienceId: experienceId,
      keyPair: keyPair,
      now: now,
    );
    final packageBytes = await File(packaged.cachePath).readAsBytes();
    return ExperienceSubmissionPackageResult(
      experienceId: packaged.experienceId,
      packageBytes: packageBytes,
      packageHash: packaged.packageHash,
      packageBytesSha256: sha256.convert(packageBytes).toString(),
      publisher: packaged.publisher,
      cachePath: packaged.cachePath,
    );
  }

  Future<void> _writeRawDump({
    required Directory contentDir,
    required ExperienceMetadata metadata,
    required String conversation,
    required String events,
    required List<ExperienceRawFile> toolFiles,
    required List<ExperienceRawFile> attachmentFiles,
  }) async {
    final rawDir = Directory(p.join(contentDir.path, 'raw'));
    await rawDir.create(recursive: true);
    await Directory(
      p.join(contentDir.path, 'tool-calls'),
    ).create(recursive: true);
    await Directory(
      p.join(contentDir.path, 'attachments'),
    ).create(recursive: true);
    await File(p.join(contentDir.path, 'metadata.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metadata.toJson()),
      flush: true,
    );
    await File(
      p.join(rawDir.path, 'conversation.md'),
    ).writeAsString(_ensureTrailingNewline(conversation), flush: true);
    await File(p.join(rawDir.path, 'events.md')).writeAsString(
      _ensureTrailingNewline(events.trim().isEmpty ? '无工具事件记录。' : events),
      flush: true,
    );
    await _writeRawFiles(
      Directory(p.join(contentDir.path, 'tool-calls')),
      toolFiles,
    );
    await _writeRawFiles(
      Directory(p.join(contentDir.path, 'attachments')),
      attachmentFiles,
    );
  }

  Future<void> _writeRawFiles(
    Directory baseDir,
    List<ExperienceRawFile> files,
  ) async {
    final base = p.normalize(baseDir.absolute.path);
    for (final file in files) {
      final relative = file.relativePath.trim().replaceAll('\\', '/');
      if (relative.isEmpty ||
          p.isAbsolute(relative) ||
          relative.split('/').contains('..')) {
        throw ArgumentError('经验文件路径无效：${file.relativePath}');
      }
      final target = File(p.joinAll([baseDir.path, ...relative.split('/')]));
      if (!_pathInside(base, target.path)) {
        throw ArgumentError('经验文件路径逃逸：${file.relativePath}');
      }
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.bytes, flush: true);
    }
  }

  Future<ExperienceReviewState?> _effectiveReviewState(
    Directory itemDir, {
    required String id,
    required ExperienceScope scope,
  }) async {
    final explicit = await _tryReadReviewState(itemDir);
    if (explicit != null) return explicit;
    if (scope == ExperienceScope.network ||
        await File(p.join(itemDir.path, 'review-materials.json')).exists()) {
      return ExperienceReviewState(
        experienceId: id,
        remoteExperienceId: id,
        status: 'network',
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
    }
    return null;
  }

  Future<ExperienceReviewState?> _tryReadReviewState(Directory itemDir) async {
    final file = File(p.join(itemDir.path, 'review-state.json'));
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return ExperienceReviewState.fromJson(decoded);
      }
      if (decoded is Map) {
        return ExperienceReviewState.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeReviewState(
    Directory itemDir,
    ExperienceReviewState state,
  ) async {
    await File(p.join(itemDir.path, 'review-state.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
      flush: true,
    );
  }

  Future<void> _deletePrivatePackageArtifacts(
    String experienceId,
    Directory itemDir,
  ) async {
    for (final path in [
      p.join(itemDir.path, 'package.zip'),
      p.join(itemDir.path, 'publisher.json'),
      p.join(itemDir.path, 'ratings.dat'),
      p.join(itemDir.path, 'review-state.json'),
      p.join(cacheDir.path, '$experienceId.hxp'),
    ]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Directory _safeChild(Directory base, String child) {
    final target = Directory(p.join(base.path, child));
    if (!_pathInside(base.path, target.path)) {
      throw ArgumentError('经验路径逃逸：$child');
    }
    return target;
  }

  Directory _baseDirForScope(ExperienceScope scope) =>
      scope == ExperienceScope.private ? privateDir : networkDir;
}

class ExperiencePackageSupplyWorkflow {
  ExperiencePackageSupplyWorkflow({
    required ExperienceStore store,
    required ExperienceDhtHttpClient dhtClient,
  }) : _store = store,
       _dhtClient = dhtClient;

  final ExperienceStore _store;
  final ExperienceDhtHttpClient _dhtClient;

  Future<ExperiencePackageOffer> buildLocalPackageOffer({
    required String experienceId,
    required String requestId,
    required String providerPeerId,
    ExperienceScope scope = ExperienceScope.private,
    List<ExperienceNetworkEndpoint> providerAddrs = const [],
    List<ExperienceTransport> availableTransports = const [],
    String? providerOwnerPeerId,
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    await _store.init();
    final id = _requireNonEmpty(experienceId, 'experienceId');
    final reqId = _requireNonEmpty(requestId, 'requestId');
    final peerId = _requireNonEmpty(providerPeerId, 'providerPeerId');
    final itemDir = _store._safeChild(_store._baseDirForScope(scope), id);
    final cacheFile = File(p.join(_store.cacheDir.path, '$id.hxp'));
    if (!await itemDir.exists() || !await cacheFile.exists()) {
      throw StateError('本地经验包不存在：$id');
    }
    final info = _readOuterPackage(await cacheFile.readAsBytes());
    final verification = _verifyReviewedOuterPackage(
      info,
      trustAnchor: trustAnchor,
      now: now,
    );
    if (!verification.ok) {
      throw StateError('本地私有经验包不能作为供给方发布：${verification.message}');
    }

    final validAddrs = providerAddrs
        .where((endpoint) => endpoint.isValid)
        .toList(growable: false);
    if (providerAddrs.isNotEmpty && validAddrs.isEmpty) {
      throw FormatException('供给方地址无效');
    }
    final transports = _normalizeTransports(
      availableTransports.isEmpty
          ? _inferAvailableTransports(validAddrs)
          : availableTransports,
    );
    final timestamp = (now ?? DateTime.now()).toUtc();
    return ExperiencePackageOffer(
      requestId: reqId,
      experienceId: info.publisher.experienceId,
      packageHash: info.publisher.packageHash,
      providerPeerId: peerId,
      providerOwnerPeerId: _normalizeOptionalString(providerOwnerPeerId),
      providerAddrs: validAddrs,
      availableTransports: transports,
      reviewMaterials: info.reviewMaterials,
      publisher: info.publisher.toJson(),
      nonce: _packageOfferNonce(
        experienceId: info.publisher.experienceId,
        requestId: reqId,
        providerPeerId: peerId,
        timestamp: timestamp,
      ),
      timestamp: timestamp,
    );
  }

  Future<ExperiencePackageOfferRecord> publishLocalPackageOffer({
    required String experienceId,
    required String requestId,
    required String providerPeerId,
    required HanakoKeyPair keyPair,
    ExperienceScope scope = ExperienceScope.private,
    List<ExperienceNetworkEndpoint> providerAddrs = const [],
    List<ExperienceTransport> availableTransports = const [],
    String? providerOwnerPeerId,
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    final offer = await buildLocalPackageOffer(
      experienceId: experienceId,
      requestId: requestId,
      providerPeerId: providerPeerId,
      scope: scope,
      providerAddrs: providerAddrs,
      availableTransports: availableTransports,
      providerOwnerPeerId: providerOwnerPeerId,
      trustAnchor: trustAnchor,
      now: now,
    );
    return _dhtClient.publishPackageOffer(
      requestId: requestId,
      offer: offer,
      keyPair: keyPair,
    );
  }

  Future<ExperienceDemandOffer> buildExperienceDemandOffer({
    required String experienceId,
    required ExperienceDemand demand,
    required String providerPeerId,
    ExperienceScope scope = ExperienceScope.private,
    List<ExperienceNetworkEndpoint> providerAddrs = const [],
    List<ExperienceTransport> availableTransports = const [],
    String? providerOwnerPeerId,
    String matchedReason = '',
    String relaySessionId = '',
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    await _store.init();
    final id = _requireNonEmpty(experienceId, 'experienceId');
    final peerId = _requireNonEmpty(providerPeerId, 'providerPeerId');
    final itemDir = _store._safeChild(_store._baseDirForScope(scope), id);
    final cacheFile = File(p.join(_store.cacheDir.path, '$id.hxp'));
    if (!await itemDir.exists() || !await cacheFile.exists()) {
      throw StateError('本地经验包不存在：$id');
    }
    final info = _readOuterPackage(await cacheFile.readAsBytes());
    final verification = _verifyReviewedOuterPackage(
      info,
      trustAnchor: trustAnchor,
      now: now,
    );
    if (!verification.ok) {
      throw StateError('本地经验包不能作为自然语言需求供给：${verification.message}');
    }
    final metadata =
        await _tryReadMetadata(
          File(p.join(itemDir.path, 'content', 'metadata.json')),
        ) ??
        _metadataFromPackage(info.packageBytes);
    final validAddrs = providerAddrs
        .where((endpoint) => endpoint.isValid)
        .toList(growable: false);
    if (providerAddrs.isNotEmpty && validAddrs.isEmpty) {
      throw FormatException('供给方地址无效');
    }
    final transports = _normalizeTransports(
      availableTransports.isEmpty
          ? _inferAvailableTransports(validAddrs)
          : availableTransports,
    );
    final timestamp = (now ?? DateTime.now()).toUtc();
    return ExperienceDemandOffer(
      requestId: demand.requestId,
      experienceId: info.publisher.experienceId,
      packageHash: info.publisher.packageHash,
      title: metadata.title,
      brief: metadata.brief,
      keywords: metadata.keywords,
      matchedReason: matchedReason.trim().isEmpty ? '本地经验索引命中' : matchedReason,
      reviewChain: _reviewChainFromRatings(info.ratingsDat),
      providerPeerId: peerId,
      providerOwnerPeerId: _normalizeOptionalString(providerOwnerPeerId),
      providerAddrs: validAddrs,
      availableTransports: transports,
      returnPath: demand.returnPath,
      relaySessionId: relaySessionId.trim(),
      nonce: _packageOfferNonce(
        experienceId: info.publisher.experienceId,
        requestId: demand.requestId,
        providerPeerId: peerId,
        timestamp: timestamp,
      ),
      timestamp: timestamp,
    );
  }

  Future<ExperienceDemandOfferRecord> publishExperienceDemandOffer({
    required String experienceId,
    required ExperienceDemand demand,
    required String providerPeerId,
    required HanakoKeyPair keyPair,
    ExperienceScope scope = ExperienceScope.private,
    List<ExperienceNetworkEndpoint> providerAddrs = const [],
    List<ExperienceTransport> availableTransports = const [],
    String? providerOwnerPeerId,
    String matchedReason = '',
    String relaySessionId = '',
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    final offer = await buildExperienceDemandOffer(
      experienceId: experienceId,
      demand: demand,
      providerPeerId: providerPeerId,
      scope: scope,
      providerAddrs: providerAddrs,
      availableTransports: availableTransports,
      providerOwnerPeerId: providerOwnerPeerId,
      matchedReason: matchedReason,
      relaySessionId: relaySessionId,
      trustAnchor: trustAnchor,
      now: now,
    );
    await _uploadOfferPackageToReturnPath(offer);
    return _dhtClient.publishExperienceDemandOffer(
      requestId: demand.requestId,
      offer: offer,
      keyPair: keyPair,
    );
  }

  Future<List<ExperienceDemandOfferRecord>> answerMatchingExperienceDemands({
    required String providerPeerId,
    required HanakoKeyPair keyPair,
    String query = '',
    int maxDemands = 20,
    int maxOffersPerDemand = 3,
    ExperienceReviewTrustAnchor? trustAnchor,
    List<ExperienceNetworkEndpoint> providerAddrs = const [],
    List<ExperienceTransport> availableTransports = const [],
    String? providerOwnerPeerId,
    DateTime? now,
  }) async {
    final demands = await _dhtClient.fetchExperienceDemands(
      query: query,
      limit: maxDemands,
    );
    final out = <ExperienceDemandOfferRecord>[];
    for (final record in demands) {
      final demand = record.demand;
      final matches = await _store.search(
        demand.naturalLanguageQuery,
        maxResults: maxOffersPerDemand,
        scopes: const {ExperienceScope.private, ExperienceScope.network},
      );
      final seen = <String>{};
      for (final match in matches) {
        final key = '${match.scope.wireName}:${match.experienceId}';
        if (!seen.add(key)) continue;
        try {
          final offer = await publishExperienceDemandOffer(
            experienceId: match.experienceId,
            demand: demand,
            providerPeerId: providerPeerId,
            keyPair: keyPair,
            scope: match.scope,
            providerAddrs: providerAddrs,
            availableTransports: availableTransports,
            providerOwnerPeerId: providerOwnerPeerId,
            matchedReason: '本地 ${match.scope.wireName} 经验命中：${match.snippet}',
            trustAnchor: trustAnchor,
            now: now,
          );
          out.add(offer);
        } catch (_) {
          continue;
        }
      }
    }
    return out;
  }

  Future<ExperienceDhtRelaySession> uploadLocalPackageToRelay({
    required String experienceId,
    required String sessionId,
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    await _store.init();
    final id = _requireNonEmpty(experienceId, 'experienceId');
    final relaySessionId = _requireNonEmpty(sessionId, 'sessionId');
    final cacheFile = File(p.join(_store.cacheDir.path, '$id.hxp'));
    if (!await cacheFile.exists()) {
      throw StateError('本地私有经验包缓存不存在：$id');
    }
    final bytes = await cacheFile.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('本地私有经验包缓存为空：$id');
    }
    final info = _readOuterPackage(bytes);
    final verification = _verifyReviewedOuterPackage(
      info,
      trustAnchor: trustAnchor,
      now: now,
    );
    if (!verification.ok) {
      throw StateError('本地私有经验包不能上传 relay：${verification.message}');
    }
    return _dhtClient.uploadRelayPackage(
      sessionId: relaySessionId,
      packageBytes: bytes,
    );
  }

  Future<void> _uploadOfferPackageToReturnPath(
    ExperienceDemandOffer offer,
  ) async {
    if (offer.returnPath.isEmpty) return;
    final cacheFile = File(
      p.join(_store.cacheDir.path, '${offer.experienceId}.hxp'),
    );
    if (!await cacheFile.exists()) return;
    final bytes = await cacheFile.readAsBytes();
    if (bytes.isEmpty) return;
    try {
      await _dhtClient.uploadCachedPackageToReturnPath(
        packageHash: offer.packageHash,
        packageBytes: bytes,
        experienceId: offer.experienceId,
        returnPath: offer.returnPath,
      );
    } catch (_) {
      return;
    }
  }
}

class ExperienceDemandPullWorkflow {
  ExperienceDemandPullWorkflow({
    required ExperienceStore store,
    required ExperienceDhtHttpClient dhtClient,
    ExperienceNetworkManagerClient? managerClient,
  }) : _store = store,
       _dhtClient = dhtClient,
       _managerClient = managerClient;

  final ExperienceStore _store;
  final ExperienceDhtHttpClient _dhtClient;
  final ExperienceNetworkManagerClient? _managerClient;

  Future<ExperienceDemandRecord> publishNaturalLanguageDemand({
    required String query,
    required String requesterPeerId,
    required HanakoKeyPair keyPair,
    String queryLanguage = 'zh-CN',
    List<String> queryKeywords = const [],
    String? requesterOwnerPeerId,
    List<ExperienceTransport> preferredTransports = const [
      ExperienceTransport.dhtRelay,
      ExperienceTransport.managerSeed,
    ],
    int ttlSeconds = 300,
    int hopLimit = 8,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final requestId = _experienceDemandRequestId(
      query: query,
      requesterPeerId: requesterPeerId,
      publicKeyHash: keyPair.publicKeyHash,
      timestamp: timestamp,
    );
    return _dhtClient.publishExperienceDemand(
      keyPair: keyPair,
      demand: ExperienceDemand(
        requestId: requestId,
        naturalLanguageQuery: _requireNonEmpty(query, 'query'),
        queryLanguage: queryLanguage,
        queryKeywords: _normalizeKeywords(queryKeywords),
        requesterPeerId: _requireNonEmpty(requesterPeerId, 'requesterPeerId'),
        requesterOwnerPeerId: _normalizeOptionalString(requesterOwnerPeerId),
        requesterPubkeyHash: keyPair.publicKeyHash,
        preferredTransports: preferredTransports,
        ttlSeconds: ttlSeconds,
        hopLimit: hopLimit,
        createdAt: timestamp,
        nonce: requestId,
      ),
    );
  }

  Future<List<ExperienceDemandOfferRecord>> collectOffers({
    required String requestId,
    int pollAttempts = 3,
    Duration pollInterval = const Duration(milliseconds: 250),
  }) async {
    final id = _requireNonEmpty(requestId, 'requestId');
    final attempts = pollAttempts <= 0 ? 1 : pollAttempts;
    var offers = const <ExperienceDemandOfferRecord>[];
    for (var i = 0; i < attempts; i++) {
      offers = await _dhtClient.fetchExperienceDemandOffers(requestId: id);
      if (offers.isNotEmpty || i == attempts - 1) break;
      await Future<void>.delayed(pollInterval);
    }
    return _sortDemandOffers(offers);
  }

  Future<ExperienceDemandPullResult> requestAndImportBestOffer({
    required String query,
    required String requesterPeerId,
    required HanakoKeyPair keyPair,
    String queryLanguage = 'zh-CN',
    List<String> queryKeywords = const [],
    String? requesterOwnerPeerId,
    ExperienceReviewTrustAnchor? trustAnchor,
    int pollAttempts = 3,
    Duration pollInterval = const Duration(milliseconds: 250),
    DateTime? now,
  }) async {
    final demand = await publishNaturalLanguageDemand(
      query: query,
      requesterPeerId: requesterPeerId,
      keyPair: keyPair,
      queryLanguage: queryLanguage,
      queryKeywords: queryKeywords,
      requesterOwnerPeerId: requesterOwnerPeerId,
      now: now,
    );
    final offers = await collectOffers(
      requestId: demand.demand.requestId,
      pollAttempts: pollAttempts,
      pollInterval: pollInterval,
    );
    if (offers.isEmpty) {
      return ExperienceDemandPullResult(
        demand: demand,
        offers: offers,
        importResult: ExperienceImportResult.failed('没有收到经验供给 offer'),
      );
    }
    final selected = offers.first;
    final imported = await importOffer(
      selected,
      trustAnchor: trustAnchor,
      now: now,
    );
    return ExperienceDemandPullResult(
      demand: demand,
      offers: offers,
      selectedOffer: selected,
      importResult: imported,
    );
  }

  Future<ExperienceImportResult> importOffer(
    ExperienceDemandOfferRecord record, {
    ExperienceReviewTrustAnchor? trustAnchor,
    DateTime? now,
  }) async {
    final offer = record.offer;
    var bytes = await _tryDownloadCachedOfferPackage(offer);
    if (bytes == null &&
        offer.relaySessionId.trim().isNotEmpty &&
        offer.availableTransports.contains(ExperienceTransport.dhtRelay)) {
      bytes = await _dhtClient.downloadRelayPackage(
        sessionId: offer.relaySessionId,
      );
    } else if (bytes == null && _managerClient != null) {
      bytes = await _managerClient.fetchPackage(
        experienceId: offer.experienceId,
      );
    } else if (bytes == null) {
      return ExperienceImportResult.failed(
        'offer 没有可用 DHT 缓存、relay 会话，且未配置管理端兜底下载',
      );
    }
    final expectedHash = _normalizePackageHashForCheck(offer.packageHash);
    if (expectedHash.isNotEmpty) {
      final actualHash = _readOuterPackage(bytes).publisher.packageHash;
      if (!_stringsEqualIgnoreCase(actualHash, expectedHash)) {
        return ExperienceImportResult.failed('下载到的经验包 Hash 与 offer 不一致');
      }
    }
    return _store.importNetworkPackage(
      bytes,
      trustAnchor: trustAnchor,
      now: now,
    );
  }

  Future<Uint8List?> _tryDownloadCachedOfferPackage(
    ExperienceDemandOffer offer,
  ) async {
    try {
      return await _dhtClient.downloadCachedPackage(
        packageHash: offer.packageHash,
        returnPath: offer.returnPath,
      );
    } catch (_) {
      return null;
    }
  }
}

class ExperienceDemandPullResult {
  const ExperienceDemandPullResult({
    required this.demand,
    required this.offers,
    this.selectedOffer,
    required this.importResult,
  });

  final ExperienceDemandRecord demand;
  final List<ExperienceDemandOfferRecord> offers;
  final ExperienceDemandOfferRecord? selectedOffer;
  final ExperienceImportResult importResult;
}

List<ExperienceTransport> _normalizeTransports(
  Iterable<ExperienceTransport> transports,
) {
  final seen = <ExperienceTransport>{};
  final out = <ExperienceTransport>[];
  for (final transport in transports) {
    if (seen.add(transport)) {
      out.add(transport);
    }
  }
  return out;
}

List<ExperienceTransport> _inferAvailableTransports(
  List<ExperienceNetworkEndpoint> endpoints,
) {
  final transports = <ExperienceTransport>[];
  if (endpoints.any((endpoint) => endpoint.isIPv6)) {
    transports.add(ExperienceTransport.ipv6Direct);
  }
  if (endpoints.any((endpoint) => endpoint.isIPv4)) {
    transports.add(ExperienceTransport.ipv4HolePunch);
  }
  transports.add(ExperienceTransport.dhtRelay);
  return transports;
}

List<Map<String, dynamic>> _reviewChainFromRatings(String ratingsDat) {
  final out = <Map<String, dynamic>>[];
  for (final line in const LineSplitter().convert(ratingsDat)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        out.add(decoded);
      } else if (decoded is Map) {
        out.add(decoded.cast<String, dynamic>());
      }
    } catch (_) {
      out.add({
        'schema_version': 'ph01.experience.ratings.raw.v1',
        'raw': trimmed,
      });
    }
  }
  return out;
}

String _packageOfferNonce({
  required String experienceId,
  required String requestId,
  required String providerPeerId,
  required DateTime timestamp,
}) {
  return sha256
      .convert(
        utf8.encode(
          [
            'ph01.experience.package_offer.nonce.v1',
            experienceId,
            requestId,
            providerPeerId,
            timestamp.toUtc().toIso8601String(),
          ].join('\n'),
        ),
      )
      .toString();
}

String _experienceDemandRequestId({
  required String query,
  required String requesterPeerId,
  required String publicKeyHash,
  required DateTime timestamp,
}) {
  final digest = sha256
      .convert(
        utf8.encode(
          [
            'ph01.experience.demand.request_id.v1',
            query.trim(),
            requesterPeerId.trim(),
            publicKeyHash.trim(),
            timestamp.toUtc().toIso8601String(),
          ].join('\n'),
        ),
      )
      .toString();
  return 'dem_${digest.substring(0, 24)}';
}

List<ExperienceDemandOfferRecord> _sortDemandOffers(
  List<ExperienceDemandOfferRecord> offers,
) {
  final out = [...offers];
  out.sort((a, b) {
    final chain = b.offer.effectiveReviewChainLength.compareTo(
      a.offer.effectiveReviewChainLength,
    );
    if (chain != 0) return chain;
    final transport = _demandOfferTransportScore(
      b.offer,
    ).compareTo(_demandOfferTransportScore(a.offer));
    if (transport != 0) return transport;
    final aTime = a.offeredAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bTime = b.offeredAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bTime.compareTo(aTime);
  });
  return out;
}

int _demandOfferTransportScore(ExperienceDemandOffer offer) {
  if (offer.relaySessionId.trim().isNotEmpty &&
      offer.availableTransports.contains(ExperienceTransport.dhtRelay)) {
    return 3;
  }
  if (offer.availableTransports.contains(ExperienceTransport.ipv6Direct)) {
    return 2;
  }
  if (offer.availableTransports.contains(ExperienceTransport.managerSeed)) {
    return 1;
  }
  return 0;
}

String _normalizePackageHashForCheck(String value) {
  final hash = value.trim();
  if (hash.toLowerCase().startsWith('sha256:')) {
    return hash.substring('sha256:'.length).trim();
  }
  return hash;
}

bool _stringsEqualIgnoreCase(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

String? _normalizeOptionalString(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return normalized;
}

String _normalizeReviewStateStatus(String status) {
  final value = status.trim().toLowerCase();
  return switch (value) {
    'approved' => 'network',
    'pending' => 'inbox',
    'pending_review' => 'inbox',
    'reviewing' => 'inbox',
    'network' => 'network',
    'inbox' => 'inbox',
    'rejected' => 'rejected',
    _ => value,
  };
}

String _requireNonEmpty(String value, String fieldName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, fieldName, 'must not be empty');
  }
  return normalized;
}

enum ExperienceScope {
  private,
  network;

  String get wireName => switch (this) {
    ExperienceScope.private => 'private',
    ExperienceScope.network => 'network',
  };
}

class ExperienceMetadata {
  const ExperienceMetadata({
    this.schemaVersion = 'ph01.experience.raw.v1',
    required this.experienceId,
    required this.title,
    this.brief = '',
    this.keywords = const [],
    required this.createdAt,
    this.sourceType = '',
    this.sourceSessionPath = '',
  });

  final String schemaVersion;
  final String experienceId;
  final String title;
  final String brief;
  final List<String> keywords;
  final String createdAt;
  final String sourceType;
  final String sourceSessionPath;

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'experience_id': experienceId,
    'title': title,
    if (brief.trim().isNotEmpty) 'brief': brief.trim(),
    if (keywords.isNotEmpty) 'keywords': keywords,
    'created_at': createdAt,
    if (sourceType.trim().isNotEmpty) 'source_type': sourceType.trim(),
    if (sourceSessionPath.trim().isNotEmpty)
      'source_session_path': sourceSessionPath.trim(),
  };

  static ExperienceMetadata fromJson(Map<String, dynamic> json) {
    return ExperienceMetadata(
      schemaVersion:
          json['schema_version']?.toString() ?? 'ph01.experience.raw.v1',
      experienceId: json['experience_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      brief: json['brief']?.toString() ?? '',
      keywords: (json['keywords'] is List)
          ? (json['keywords'] as List)
                .map((item) => item.toString())
                .where((item) => item.trim().isNotEmpty)
                .toList(growable: false)
          : const [],
      createdAt:
          json['created_at']?.toString() ??
          DateTime.now().toUtc().toIso8601String(),
      sourceType: json['source_type']?.toString() ?? '',
      sourceSessionPath: json['source_session_path']?.toString() ?? '',
    );
  }
}

class ExperienceRawFile {
  const ExperienceRawFile({required this.relativePath, required this.bytes});

  factory ExperienceRawFile.text(String relativePath, String content) =>
      ExperienceRawFile(
        relativePath: relativePath,
        bytes: Uint8List.fromList(utf8.encode(content)),
      );

  final String relativePath;
  final Uint8List bytes;
}

class ExperiencePublisher {
  const ExperiencePublisher({
    this.schemaVersion = 'ph01.experience.publisher.v1',
    required this.experienceId,
    required this.packageHash,
    this.packageHashAlgorithm = 'sha256',
    required this.publisherPubkey,
    required this.publisherPubkeyHash,
    required this.signatureAlgorithm,
    required this.signature,
    required this.createdAt,
  });

  final String schemaVersion;
  final String experienceId;
  final String packageHash;
  final String packageHashAlgorithm;
  final String publisherPubkey;
  final String publisherPubkeyHash;
  final String signatureAlgorithm;
  final String signature;
  final String createdAt;

  static const algorithm = 'secp256k1_ecdsa_sha256_rs64';

  static ExperiencePublisher sign({
    required String experienceId,
    required Uint8List packageBytes,
    required HanakoKeyPair keyPair,
    required DateTime createdAt,
  }) {
    final packageHash = sha256.convert(packageBytes).toString();
    final created = createdAt.toUtc().toIso8601String();
    final payload = signaturePayload(
      experienceId: experienceId,
      packageHash: packageHash,
      publisherPubkey: keyPair.publicKeyHex,
      createdAt: created,
    );
    final signature = keyPair.sign(Uint8List.fromList(utf8.encode(payload)));
    return ExperiencePublisher(
      experienceId: experienceId,
      packageHash: packageHash,
      publisherPubkey: keyPair.publicKeyHex,
      publisherPubkeyHash: keyPair.publicKeyHash,
      signatureAlgorithm: algorithm,
      signature: _hexEncode(signature),
      createdAt: created,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'experience_id': experienceId,
    'package_hash_algorithm': packageHashAlgorithm,
    'package_hash': packageHash,
    'publisher_pubkey': publisherPubkey,
    'publisher_pubkey_hash': publisherPubkeyHash,
    'signature_algorithm': signatureAlgorithm,
    'signature': signature,
    'created_at': createdAt,
  };

  static ExperiencePublisher fromJson(Map<String, dynamic> json) {
    return ExperiencePublisher(
      schemaVersion:
          json['schema_version']?.toString() ?? 'ph01.experience.publisher.v1',
      experienceId: json['experience_id']?.toString() ?? '',
      packageHash:
          json['package_hash']?.toString() ??
          json['content_hash']?.toString() ??
          '',
      packageHashAlgorithm:
          json['package_hash_algorithm']?.toString() ?? 'sha256',
      publisherPubkey: json['publisher_pubkey']?.toString() ?? '',
      publisherPubkeyHash: json['publisher_pubkey_hash']?.toString() ?? '',
      signatureAlgorithm: json['signature_algorithm']?.toString() ?? algorithm,
      signature: json['signature']?.toString() ?? '',
      createdAt:
          json['created_at']?.toString() ??
          DateTime.now().toUtc().toIso8601String(),
    );
  }

  ExperienceVerificationResult verifyPackage(Uint8List packageBytes) {
    if (experienceId.trim().isEmpty) {
      return ExperienceVerificationResult(false, 'publisher.json 缺少经验 ID');
    }
    if (packageHashAlgorithm != 'sha256') {
      return ExperienceVerificationResult(false, '不支持的包 hash 算法');
    }
    final actualHash = sha256.convert(packageBytes).toString();
    if (actualHash != packageHash) {
      return ExperienceVerificationResult(false, 'package.zip hash 不一致');
    }
    if (signatureAlgorithm != algorithm) {
      return ExperienceVerificationResult(false, '不支持的发布者签名算法');
    }
    try {
      final ok = HanakoKeyPair.verify(
        message: Uint8List.fromList(
          utf8.encode(
            signaturePayload(
              experienceId: experienceId,
              packageHash: packageHash,
              publisherPubkey: publisherPubkey,
              createdAt: createdAt,
            ),
          ),
        ),
        signature64: _hexDecode(signature),
        publicKeyBytes65: _hexDecode(publisherPubkey),
      );
      if (!ok) {
        return ExperienceVerificationResult(false, '发布者签名验证失败');
      }
      return const ExperienceVerificationResult(true, '验证通过');
    } catch (e) {
      return ExperienceVerificationResult(false, '发布者签名材料无效：$e');
    }
  }

  static String signaturePayload({
    required String experienceId,
    required String packageHash,
    required String publisherPubkey,
    required String createdAt,
  }) => [
    'ph01.experience.publisher.v1',
    experienceId,
    packageHash,
    publisherPubkey,
    createdAt,
  ].join('\n');
}

class ExperienceVerificationResult {
  const ExperienceVerificationResult(this.ok, this.message);
  final bool ok;
  final String message;
}

class ExperiencePackageResult {
  const ExperiencePackageResult({
    required this.experienceId,
    required this.scope,
    required this.path,
    required this.contentPath,
    required this.packagePath,
    required this.publisherPath,
    required this.ratingsPath,
    required this.cachePath,
    required this.packageHash,
    required this.publisher,
  });

  final String experienceId;
  final ExperienceScope scope;
  final String path;
  final String contentPath;
  final String packagePath;
  final String publisherPath;
  final String ratingsPath;
  final String cachePath;
  final String packageHash;
  final ExperiencePublisher publisher;
}

class ExperienceSubmissionPackageResult {
  const ExperienceSubmissionPackageResult({
    required this.experienceId,
    required this.packageBytes,
    required this.packageHash,
    required this.packageBytesSha256,
    required this.publisher,
    this.cachePath,
  });

  final String experienceId;
  final Uint8List packageBytes;

  /// Hash of the inner `package.zip` content, used by publisher/review chains.
  final String packageHash;

  /// Hash of the uploaded outer `.hxp` bytes, used by package PoW.
  final String packageBytesSha256;
  final ExperiencePublisher publisher;
  final String? cachePath;
}

class ExperienceReviewAttachResult {
  const ExperienceReviewAttachResult._({
    required this.ok,
    required this.message,
    this.needsFullPackage = false,
    this.experienceId,
    this.cachePath,
    this.reviewMaterialsPath,
  });

  factory ExperienceReviewAttachResult.success({
    required String experienceId,
    required String cachePath,
    required String reviewMaterialsPath,
  }) => ExperienceReviewAttachResult._(
    ok: true,
    message: '审核材料已附加',
    experienceId: experienceId,
    cachePath: cachePath,
    reviewMaterialsPath: reviewMaterialsPath,
  );

  factory ExperienceReviewAttachResult.incomplete(String message) =>
      ExperienceReviewAttachResult._(
        ok: false,
        message: message,
        needsFullPackage: true,
      );

  factory ExperienceReviewAttachResult.failed(String message) =>
      ExperienceReviewAttachResult._(ok: false, message: message);

  final bool ok;
  final String message;
  final bool needsFullPackage;
  final String? experienceId;
  final String? cachePath;
  final String? reviewMaterialsPath;
}

class ExperienceSaveResult {
  const ExperienceSaveResult({
    required this.experienceId,
    required this.scope,
    required this.path,
    required this.contentPath,
    required this.metadataPath,
    required this.metadata,
  });

  final String experienceId;
  final ExperienceScope scope;
  final String path;
  final String contentPath;
  final String metadataPath;
  final ExperienceMetadata metadata;
}

class ExperienceImportResult {
  const ExperienceImportResult._({
    required this.ok,
    required this.message,
    this.experienceId,
    this.path,
    this.cachePath,
    this.packageHash,
  });

  factory ExperienceImportResult.success({
    required String experienceId,
    required String path,
    required String cachePath,
    required String packageHash,
  }) => ExperienceImportResult._(
    ok: true,
    message: '导入成功',
    experienceId: experienceId,
    path: path,
    cachePath: cachePath,
    packageHash: packageHash,
  );

  factory ExperienceImportResult.failed(String message) =>
      ExperienceImportResult._(ok: false, message: message);

  final bool ok;
  final String message;
  final String? experienceId;
  final String? path;
  final String? cachePath;
  final String? packageHash;
}

class ExperienceSearchResult {
  const ExperienceSearchResult({
    required this.experienceId,
    required this.scope,
    required this.title,
    required this.filePath,
    required this.relativePath,
    required this.line,
    required this.snippet,
    this.metadata,
  });

  final String experienceId;
  final ExperienceScope scope;
  final String title;
  final String filePath;
  final String relativePath;
  final int line;
  final String snippet;
  final ExperienceMetadata? metadata;

  Map<String, dynamic> toJson() => {
    'experience_id': experienceId,
    'scope': scope.wireName,
    'title': title,
    'path': filePath,
    'relative_path': relativePath,
    'line': line,
    'snippet': snippet,
    if (metadata != null) 'metadata': metadata!.toJson(),
  };
}

class ExperienceListItem {
  const ExperienceListItem({
    required this.experienceId,
    required this.scope,
    required this.title,
    required this.path,
    this.metadata,
    this.reviewState,
  });

  final String experienceId;
  final ExperienceScope scope;
  final String title;
  final String path;
  final ExperienceMetadata? metadata;
  final ExperienceReviewState? reviewState;

  Map<String, dynamic> toJson() => {
    'experience_id': experienceId,
    'scope': scope.wireName,
    'title': title,
    'path': path,
    if (metadata != null) 'metadata': metadata!.toJson(),
    if (reviewState != null) 'review_state': reviewState!.toJson(),
  };
}

class ExperienceReviewState {
  const ExperienceReviewState({
    this.schemaVersion = 'ph01.experience.local_review_state.v1',
    required this.experienceId,
    this.remoteExperienceId = '',
    this.status = '',
    this.submittedAt = '',
    this.updatedAt = '',
    this.packageBytesSha256 = '',
    this.packageHash = '',
    this.reviewReason = '',
  });

  final String schemaVersion;
  final String experienceId;
  final String remoteExperienceId;
  final String status;
  final String submittedAt;
  final String updatedAt;
  final String packageBytesSha256;
  final String packageHash;
  final String reviewReason;

  bool get submitted => status == 'inbox' || status == 'network';
  bool get pendingReview => status == 'inbox';
  bool get approved => status == 'network';

  String get effectiveRemoteExperienceId =>
      remoteExperienceId.trim().isEmpty ? experienceId : remoteExperienceId;

  String get displayLabel => switch (status) {
    'network' => '已通过审核',
    'inbox' => '已提交，等待审核',
    'rejected' => '审核未通过',
    _ => status.trim().isEmpty ? '未提交' : status,
  };

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'experience_id': experienceId,
    if (remoteExperienceId.trim().isNotEmpty)
      'remote_experience_id': remoteExperienceId.trim(),
    if (status.trim().isNotEmpty) 'status': status.trim(),
    if (submittedAt.trim().isNotEmpty) 'submitted_at': submittedAt.trim(),
    if (updatedAt.trim().isNotEmpty) 'updated_at': updatedAt.trim(),
    if (packageBytesSha256.trim().isNotEmpty)
      'package_bytes_sha256': packageBytesSha256.trim(),
    if (packageHash.trim().isNotEmpty) 'package_hash': packageHash.trim(),
    if (reviewReason.trim().isNotEmpty) 'review_reason': reviewReason.trim(),
  };

  static ExperienceReviewState? fromJson(Map<String, dynamic> json) {
    final id = json['experience_id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    return ExperienceReviewState(
      schemaVersion:
          json['schema_version']?.toString() ??
          'ph01.experience.local_review_state.v1',
      experienceId: id,
      remoteExperienceId: json['remote_experience_id']?.toString() ?? '',
      status: _normalizeReviewStateStatus(json['status']?.toString() ?? ''),
      submittedAt: json['submitted_at']?.toString() ?? '',
      updatedAt: json['updated_at']?.toString() ?? '',
      packageBytesSha256: json['package_bytes_sha256']?.toString() ?? '',
      packageHash: json['package_hash']?.toString() ?? '',
      reviewReason: json['review_reason']?.toString() ?? '',
    );
  }
}

class _OuterPackageInfo {
  const _OuterPackageInfo({
    required this.packageBytes,
    required this.publisher,
    required this.ratingsDat,
    this.reviewMaterials,
  });

  final Uint8List packageBytes;
  final ExperiencePublisher publisher;
  final String ratingsDat;
  final ExperienceReviewMaterials? reviewMaterials;
}

Future<Uint8List> _packDirectory(Directory dir) async {
  final root = p.normalize(dir.absolute.path);
  final archive = Archive();
  if (!await dir.exists()) {
    throw ArgumentError('原始经验目录不存在：${dir.path}');
  }
  final entities = await dir.list(recursive: true, followLinks: false).toList();
  entities.sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    final rel = p
        .relative(entity.path, from: root)
        .split(p.separator)
        .join('/');
    final clean = _cleanArchiveName(rel);
    if (clean == null) {
      throw ArgumentError('经验包路径非法：$rel');
    }
    final stat = await entity.stat();
    if (stat.type == FileSystemEntityType.link) {
      throw ArgumentError('经验包不允许包含符号链接：$rel');
    }
    if (entity is Directory) {
      archive.add(
        ArchiveFile.directory(clean.endsWith('/') ? clean : '$clean/'),
      );
    } else if (entity is File) {
      archive.add(ArchiveFile.bytes(clean, await entity.readAsBytes()));
    }
  }
  return ZipEncoder().encodeBytes(archive, autoClose: false);
}

Uint8List _buildOuterPackage({
  required Uint8List packageBytes,
  required ExperiencePublisher publisher,
  required String ratingsDat,
  ExperienceReviewMaterials? reviewMaterials,
}) {
  final archive = Archive()
    ..add(ArchiveFile.bytes('package.zip', packageBytes))
    ..add(
      ArchiveFile.string(
        'publisher.json',
        const JsonEncoder.withIndent('  ').convert(publisher.toJson()),
      ),
    )
    ..add(ArchiveFile.string('ratings.dat', ratingsDat));
  if (reviewMaterials != null) {
    archive.add(
      ArchiveFile.string(
        'review-materials.json',
        const JsonEncoder.withIndent('  ').convert(reviewMaterials.toJson()),
      ),
    );
  }
  return ZipEncoder().encodeBytes(archive, autoClose: false);
}

_OuterPackageInfo _readOuterPackage(Uint8List hxpBytes) {
  final archive = ZipDecoder().decodeBytes(hxpBytes);
  final packageFile = archive.findFile('package.zip');
  final publisherFile = archive.findFile('publisher.json');
  final ratingsFile = archive.findFile('ratings.dat');
  final reviewFile =
      archive.findFile('review-materials.json') ??
      archive.findFile('review_materials.json');
  if (packageFile == null) {
    throw const FormatException('经验包缺少 package.zip');
  }
  if (publisherFile == null) {
    throw const FormatException('经验包缺少 publisher.json');
  }
  if (ratingsFile == null) {
    throw const FormatException('经验包缺少 ratings.dat');
  }
  final packageBytes = packageFile.content;
  ZipDecoder().decodeBytes(packageBytes);
  final publisherJson =
      jsonDecode(utf8.decode(publisherFile.content)) as Map<String, dynamic>;
  return _OuterPackageInfo(
    packageBytes: packageBytes,
    publisher: ExperiencePublisher.fromJson(publisherJson),
    ratingsDat: utf8.decode(ratingsFile.content),
    reviewMaterials: reviewFile == null
        ? null
        : ExperienceReviewMaterials.fromJson(
            (jsonDecode(utf8.decode(reviewFile.content)) as Map)
                .cast<String, dynamic>(),
          ),
  );
}

ExperienceVerificationResult _verifyReviewedOuterPackage(
  _OuterPackageInfo info, {
  ExperienceReviewTrustAnchor? trustAnchor,
  DateTime? now,
}) {
  final publisherVerification = info.publisher.verifyPackage(info.packageBytes);
  if (!publisherVerification.ok) return publisherVerification;
  if (info.reviewMaterials == null) {
    return const ExperienceVerificationResult(false, '网络经验缺少审核签名材料');
  }
  final reviewVerification = info.reviewMaterials!.verify(
    experienceId: info.publisher.experienceId,
    packageHash: info.publisher.packageHash,
    publisherPubkey: info.publisher.publisherPubkey,
    trustAnchor: trustAnchor,
    now: now,
  );
  return ExperienceVerificationResult(
    reviewVerification.ok,
    reviewVerification.message,
  );
}

Future<void> _extractZip(Uint8List zipBytes, Directory dest) async {
  final base = p.normalize(dest.absolute.path);
  await dest.create(recursive: true);
  final archive = ZipDecoder().decodeBytes(zipBytes);
  for (final entry in archive.files) {
    if (entry.isSymbolicLink) {
      throw ArgumentError('经验包不允许包含符号链接：${entry.name}');
    }
    final clean = _cleanArchiveName(entry.name);
    if (clean == null) {
      throw ArgumentError('经验包路径非法：${entry.name}');
    }
    final target = p.normalize(p.joinAll([base, ...clean.split('/')]));
    if (!_pathInside(base, target)) {
      throw ArgumentError('经验包路径逃逸：${entry.name}');
    }
    if (entry.isDirectory) {
      await Directory(target).create(recursive: true);
    } else {
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.content, flush: true);
    }
  }
}

ExperienceMetadata _metadataFromPackage(Uint8List packageBytes) {
  final archive = ZipDecoder().decodeBytes(packageBytes);
  final file = archive.findFile('metadata.json');
  if (file == null) {
    final id = _idFromPackageHash(packageBytes);
    return ExperienceMetadata(
      experienceId: id,
      title: id,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
  final json = jsonDecode(utf8.decode(file.content)) as Map<String, dynamic>;
  final metadata = ExperienceMetadata.fromJson(json);
  if (metadata.experienceId.trim().isEmpty) {
    final id = _idFromPackageHash(packageBytes);
    return ExperienceMetadata(
      experienceId: id,
      title: metadata.title.trim().isEmpty ? id : metadata.title,
      brief: metadata.brief,
      keywords: metadata.keywords,
      createdAt: metadata.createdAt,
    );
  }
  _validateExperienceId(metadata.experienceId);
  return metadata;
}

Future<ExperienceMetadata?> _tryReadMetadata(File file) async {
  if (!await file.exists()) return null;
  try {
    final raw = jsonDecode(await file.readAsString());
    if (raw is Map<String, dynamic>) return ExperienceMetadata.fromJson(raw);
    if (raw is Map) {
      return ExperienceMetadata.fromJson(raw.cast<String, dynamic>());
    }
  } catch (_) {}
  return null;
}

String _initialRatingsDat(
  String experienceId,
  String packageHash,
  DateTime createdAt,
) {
  return '${jsonEncode({'schema_version': 'ph01.experience.ratings.v1', 'type': 'root', 'experience_id': experienceId, 'package_hash': packageHash, 'created_at': createdAt.toUtc().toIso8601String()})}\n';
}

String _newExperienceId(String title, DateTime createdAt) {
  final stamp = createdAt
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[^0-9]'), '')
      .substring(0, 14);
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  final hash = sha256.convert(
    utf8.encode('$title\n${createdAt.toIso8601String()}'),
  );
  final suffix = hash.toString().substring(0, 8);
  final middle = slug.isEmpty ? 'local' : slug;
  return 'exp_${stamp}_${middle}_$suffix';
}

String _idFromPackageHash(Uint8List packageBytes) {
  final hash = sha256.convert(packageBytes).toString();
  return 'exp_${hash.substring(0, 16)}';
}

void _validateExperienceId(String id) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$').hasMatch(id)) {
    throw ArgumentError('非法经验 ID：$id');
  }
}

String? _cleanArchiveName(String name) {
  var clean = name.trim().replaceAll('\\', '/');
  while (clean.startsWith('/')) {
    clean = clean.substring(1);
  }
  clean = p.posix.normalize(clean);
  if (clean == '.' || clean == '..' || clean.startsWith('../')) return null;
  return clean;
}

bool _pathInside(String root, String target) {
  final rootAbs = p.normalize(p.absolute(root));
  final targetAbs = p.normalize(p.absolute(target));
  return p.equals(rootAbs, targetAbs) || p.isWithin(rootAbs, targetAbs);
}

List<String> _normalizeKeywords(List<String> keywords) {
  final seen = <String>{};
  final out = <String>[];
  for (final keyword in keywords) {
    final value = keyword.trim().toLowerCase();
    if (value.isEmpty || seen.contains(value)) continue;
    seen.add(value);
    out.add(value);
  }
  out.sort();
  return out;
}

bool _isSearchableTextFile(String path) {
  switch (p.extension(path).toLowerCase()) {
    case '.md':
    case '.txt':
    case '.json':
    case '.jsonl':
    case '.dat':
    case '.log':
    case '.yaml':
    case '.yml':
    case '.csv':
      return true;
    default:
      return false;
  }
}

String _snippet(String line, int matchStart, int matchLength) {
  final runes = line.runes.toList();
  final prefixRunes = line.substring(0, matchStart).runes.length;
  final matchRunes = line
      .substring(matchStart, matchStart + matchLength)
      .runes
      .length;
  var start = prefixRunes - 60;
  if (start < 0) start = 0;
  var end = prefixRunes + matchRunes + 60;
  if (end > runes.length) end = runes.length;
  final text = String.fromCharCodes(runes.sublist(start, end));
  return '${start > 0 ? '...' : ''}$text${end < runes.length ? '...' : ''}';
}

String _ensureTrailingNewline(String text) =>
    text.endsWith('\n') ? text : '$text\n';

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

Uint8List _hexDecode(String hex) {
  final clean = hex.trim().replaceAll(' ', '');
  if (clean.length.isOdd) throw ArgumentError('hex 长度必须为偶数');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
