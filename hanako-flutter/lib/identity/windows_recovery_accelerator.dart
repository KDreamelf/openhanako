import 'dart:async';
import 'dart:io';

import '../windows_ops/windows_ops_client.dart';
import 'recovery_accelerator.dart';
import 'word_dict.dart';

class WindowsRecoveryAccelerator implements RecoveryAccelerator {
  const WindowsRecoveryAccelerator();

  @override
  Future<AcceleratedRecoveryOutcome> tryRecover({
    required List<List<int>> matrix,
    required Set<String> targetPublicKeyHashes,
    required int dMaxHard,
    required Duration hardDeadline,
    int? workerCount,
    void Function(int attempted, int elapsedMs, int currentHammingDistance)?
    onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows 原生恢复后端仅在 Windows 上可用');
    }
    final client = WindowsOpsClient(
      requestTimeout: hardDeadline + const Duration(seconds: 30),
    );
    final params = <String, dynamic>{
      'matrix': matrix,
      'wordlist': hanakoWordlist,
      'target_hashes': targetPublicKeyHashes.toList(growable: false),
      'd_max_hard': dMaxHard,
      'deadline_ms': hardDeadline.inMilliseconds,
    };
    if (workerCount != null) {
      params['worker_count'] = workerCount;
    }
    try {
      final result = await client.call(
        'recovery.search',
        params: params,
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress(
                _intValue(progress['attempted']),
                _intValue(progress['elapsed_ms']),
                _intValue(progress['hamming_distance']),
              ),
      );
      return _parseOutcome(result);
    } finally {
      await client.dispose();
    }
  }

  AcceleratedRecoveryOutcome _parseOutcome(Map<String, dynamic> result) {
    final idsRaw = result['ids'];
    return AcceleratedRecoveryOutcome(
      found: result['found'] == true,
      ids: idsRaw is List ? idsRaw.map((value) => value as int).toList() : null,
      publicKeyHex: result['public_key_hex']?.toString(),
      attempted: _intValue(result['attempted']),
      elapsedMs: _intValue(result['elapsed_ms']),
      hammingDistance: _intValue(result['hamming_distance']),
      timedOut: result['timed_out'] == true,
      backend: result['backend']?.toString() ?? 'windows_ops',
    );
  }

  int _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
