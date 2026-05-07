import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';

void main() {
  test('WindowsRecoveryAccelerator sidecar 端到端恢复 rank-0 矩阵', () async {
    if (!Platform.isWindows ||
        Platform.environment['HANAKO_RUN_SIDECAR_TEST'] != '1') {
      markTestSkipped('需要 Windows sidecar release 产物，默认跳过');
      return;
    }

    final mnemonic = generateMnemonic();
    final pair = HanakoKeyPair.fromPrivateKeyBytes(mnemonic.privateKeyBytes);
    final ids = mnemonic.words.map((word) => idByWord(word)!).toList();
    final accelerator = const WindowsRecoveryAccelerator();

    final outcome = await accelerator.tryRecover(
      matrix: [
        for (final id in ids) [id],
      ],
      targetPublicKeyHashes: {pair.publicKeyHash},
      dMaxHard: 0,
      hardDeadline: const Duration(seconds: 30),
      workerCount: 1,
    );

    expect(outcome.found, isTrue);
    expect(outcome.ids, ids);
    expect(outcome.publicKeyHex, pair.publicKeyHex);
    expect(outcome.hammingDistance, 0);
    expect(outcome.backend, startsWith('cuda:'));

    var progressEvents = 0;
    final progressOutcome = await accelerator.tryRecover(
      matrix: [
        for (final id in ids)
          [
            id,
            (id + 1) % hanakoWordlistSize,
            (id + 2) % hanakoWordlistSize,
            (id + 3) % hanakoWordlistSize,
            (id + 4) % hanakoWordlistSize,
          ],
      ],
      targetPublicKeyHashes: {
        '0000000000000000000000000000000000000000000000000000000000000000',
      },
      dMaxHard: 4,
      hardDeadline: const Duration(seconds: 30),
      workerCount: 1,
      onProgress: (attempted, elapsedMs, currentHammingDistance) {
        progressEvents++;
      },
    );
    expect(progressOutcome.found, isFalse);
    expect(progressEvents, greaterThan(0));
  });
}
