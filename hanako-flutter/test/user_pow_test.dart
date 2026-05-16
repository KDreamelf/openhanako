import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/identity/identity.dart';

void main() {
  test(
    'user PoW background solver reports progress and solves challenge',
    () async {
      final challenge = UserPowChallenge(
        challengeId: 'test-pow',
        pubkeyHash:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        algorithm: 'ph01.memory_pow.v1',
        difficultyBits: 4,
        memoryKiB: 16,
        roundCount: 1,
        seed: 'test-seed',
        expiresAt:
            DateTime.now()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch ~/
            1000,
      );

      final progress = <UserPowProgress>[];
      final nonce = await solveUserPowInBackground(
        challenge,
        maxAttempts: 1 << 16,
        workerCount: 1,
        onProgress: progress.add,
      );

      expect(nonce, 'f');
      expect(progress, isNotEmpty);
      expect(progress.first.stage, UserPowProgressStage.compute);
      expect(progress.last.completed, 256);
      expect(progress.last.total, 512);
      expect(progress.last.fraction, lessThan(1));
      expect(solveUserPow(challenge, maxAttempts: 1 << 16), nonce);
    },
  );

  test('user PoW background solver can use multiple workers', () async {
    final challenge = UserPowChallenge(
      challengeId: 'test-pow-workers',
      pubkeyHash:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      algorithm: 'ph01.memory_pow.v1',
      difficultyBits: 4,
      memoryKiB: 16,
      roundCount: 1,
      seed: 'test-seed',
      expiresAt:
          DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch ~/
          1000,
    );

    final progress = <UserPowProgress>[];
    final nonce = await solveUserPowInBackground(
      challenge,
      maxAttempts: 1 << 16,
      workerCount: 2,
      onProgress: progress.add,
    );

    expect(nonce, isNotEmpty);
    expect(progress, isNotEmpty);
    expect(progress.any((item) => item.message.contains('2 个计算任务')), true);
  });
}
