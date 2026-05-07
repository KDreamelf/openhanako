import 'dart:async';

class AcceleratedRecoveryOutcome {
  const AcceleratedRecoveryOutcome({
    required this.found,
    required this.ids,
    required this.publicKeyHex,
    required this.attempted,
    required this.elapsedMs,
    required this.hammingDistance,
    required this.timedOut,
    required this.backend,
  });

  final bool found;
  final List<int>? ids;
  final String? publicKeyHex;
  final int attempted;
  final int elapsedMs;
  final int hammingDistance;
  final bool timedOut;
  final String backend;
}

class AcceleratedRecoveryProgress {
  AcceleratedRecoveryProgress({
    required this.attempted,
    required this.elapsedMs,
    required this.currentHammingDistance,
    this.combinationId,
    List<int> candidateRanks = const [],
    List<int> wordIds = const [],
    List<int> activePositions = const [],
  }) : candidateRanks = List<int>.unmodifiable(candidateRanks),
       wordIds = List<int>.unmodifiable(wordIds),
       activePositions = List<int>.unmodifiable(activePositions);

  final int attempted;
  final int elapsedMs;
  final int currentHammingDistance;
  final int? combinationId;
  final List<int> candidateRanks;
  final List<int> wordIds;
  final List<int> activePositions;
}

abstract class RecoveryAccelerator {
  Future<AcceleratedRecoveryOutcome> tryRecover({
    required List<List<int>> matrix,
    required Set<String> targetPublicKeyHashes,
    required int dMaxHard,
    required Duration hardDeadline,
    int? workerCount,
    void Function(AcceleratedRecoveryProgress progress)? onProgress,
  });
}
