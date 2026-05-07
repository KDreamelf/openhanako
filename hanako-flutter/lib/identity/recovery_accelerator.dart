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

abstract class RecoveryAccelerator {
  Future<AcceleratedRecoveryOutcome> tryRecover({
    required List<List<int>> matrix,
    required Set<String> targetPublicKeyHashes,
    required int dMaxHard,
    required Duration hardDeadline,
    int? workerCount,
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
  });
}
