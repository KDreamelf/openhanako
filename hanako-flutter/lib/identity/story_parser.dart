// lib/identity/story_parser.dart
//
// 故事解析器：恢复期把用户的模糊故事 / 词组列表交给 LLM，让它在字典中找
// 到对应词的"候选矩阵"——12 列（按故事意象顺序）× K 行（每列 top-K
// 候选，按语义相似度从高到低）。
//
// 与 MVP §10.5 对齐 + v2 改造（按用户 2026-04-27 设计）：
//   - 旧版本输出扁平 ID 列表，客户端做全排列穷举，最坏 12! 次。
//   - 新版本输出 12×K 矩阵，客户端按汉明距离递增枚举，最坏 K^12 次。
//     第一阶段默认 K=2，全空间 2^12=4096，可直接 D=12 全量验证。
//     通过 RFA 后可显式提高到 K=3/K=4 做深度恢复。
//
// 矩阵协议：
//   {
//     "columns": [
//       [12, 73],          // 第 1 个意象：top-2 ID（rank-0 最像）
//       [451, 980],        // 第 2 个意象：top-2 ID
//       ...
//       [...]              // 共 12 列
//     ]
//   }

import 'dart:convert';

import 'word_dict.dart';
import 'story_composer.dart' show StoryLlmCaller;

/// 第一阶段每列候选数（与 recovery.dart 中的 K 对齐）。
/// K=2 时全矩阵只有 4096 个组合，可直接 D=12 全量验证。
const int kStoryParserCandidatesPerColumn = 2;

/// 期望的列数（即助记词长度，固定 12）。
const int kStoryParserColumns = 12;

class StoryParseResult {
  StoryParseResult({
    required this.columns,
    required this.rawResponse,
    required this.candidatesPerColumn,
  });

  /// 12 × K 矩阵。每行（外层）是按用户故事顺序的一个意象，每列内是该意象
  /// 的 top-K 候选 ID（rank-0 最像，rank-K-1 最不像）。
  final List<List<int>> columns;

  /// LLM 的原始返回，用于 debug。
  final String rawResponse;

  /// 本次矩阵每列候选数。
  final int candidatesPerColumn;

  /// 是否符合协议（12 列 × K 候选 + 全部 ID 在字典范围内）。
  bool get isWellFormed {
    if (columns.length != kStoryParserColumns) return false;
    for (final col in columns) {
      if (col.length != candidatesPerColumn) return false;
      for (final id in col) {
        if (id < 0 || id >= hanakoWordlistSize) return false;
      }
    }
    return true;
  }
}

class StoryParser {
  StoryParser({
    required this.caller,
    this.candidatesPerColumn = kStoryParserCandidatesPerColumn,
  }) {
    if (candidatesPerColumn < 1) {
      throw ArgumentError('candidatesPerColumn 必须大于 0');
    }
  }

  final StoryLlmCaller caller;
  final int candidatesPerColumn;

  /// 恢复期入口：用户输入 → 12×K 矩阵。
  ///
  /// [storyOrWords] 可以是模糊故事，也可以是用空格 / 逗号分隔的词组。
  Future<StoryParseResult> parse(String storyOrWords) async {
    final exactWords = _tryParseExactWords(storyOrWords);
    if (exactWords != null) {
      return StoryParseResult(
        columns: exactWords,
        rawResponse: jsonEncode({'columns': exactWords}),
        candidatesPerColumn: candidatesPerColumn,
      );
    }

    final raw = await caller(
      systemPrompt: _buildSystemPrompt(),
      userPrompt: storyOrWords,
      maxTokens: 1500,
    );
    final cols = _extractMatrix(raw);
    return StoryParseResult(
      columns: cols,
      rawResponse: raw,
      candidatesPerColumn: candidatesPerColumn,
    );
  }

  /// 系统提示词。字典本体随提示词一并发给 LLM。
  String _buildSystemPrompt() {
    final rowShape = List.filled(candidatesPerColumn, 'id').join(',');
    final exampleRows = <String>[];
    for (var row = 0; row < kStoryParserColumns; row++) {
      final values = <int>[];
      for (var col = 0; col < candidatesPerColumn; col++) {
        values.add((row * 137 + col * 29 + 12) % hanakoWordlistSize);
      }
      exampleRows.add('[${values.join(',')}]');
    }
    final dictJson = StringBuffer('{');
    for (var i = 0; i < hanakoWordlistSize; i++) {
      if (i > 0) dictJson.write(',');
      dictJson.write('"$i":"${hanakoWordlist[i]}"');
    }
    dictJson.write('}');

    return '''
你是一个语义匹配器，负责把用户描述的"故事"或"词组"映射到中文名词字典中的 ID。

任务规则：
1. 用户给你的内容是一段故事或一组关键词；故事里隐含 $kStoryParserColumns 个核心意象。
2. **按故事中意象出现的顺序**，把每个意象转成字典中最接近的 $candidatesPerColumn 个候选 ID（按相似度从高到低）。
3. 同义词必须映射（如"西红柿"→"番茄"，"太空"→"宇宙"，"风琴"→"钢琴"）。
4. 候选词的语义要尽量贴近，避免硬塞无关词。
5. 如果你确实只能想到不足 $candidatesPerColumn 个候选，用最相似的那个重复填满。
6. 只输出严格的 JSON：{"columns":[[$rowShape],[$rowShape],...]}，恰好 $kStoryParserColumns 个数组，每个数组恰好 $candidatesPerColumn 个整数。
7. 不要输出任何解释、Markdown、前缀、注释。

输出格式示例：
{"columns":[${exampleRows.join(',')}]}

字典：$dictJson
''';
  }

  /// 从 LLM 文本里抽出矩阵。容忍包裹的 ```json 代码块、前后空白等噪声。
  List<List<int>> _extractMatrix(String raw) {
    // 找 JSON 主体
    final braceStart = raw.indexOf('{');
    final braceEnd = raw.lastIndexOf('}');
    if (braceStart < 0 || braceEnd <= braceStart) {
      return _emptyMatrix();
    }
    final jsonStr = raw.substring(braceStart, braceEnd + 1);
    Map<String, dynamic> obj;
    try {
      obj = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return _emptyMatrix();
    }
    final cols = obj['columns'];
    if (cols is! List) return _emptyMatrix();

    final out = <List<int>>[];
    for (final c in cols) {
      if (c is! List) continue;
      final row = <int>[];
      for (final v in c) {
        if (v is int) {
          row.add(v);
        } else if (v is num) {
          row.add(v.toInt());
        }
      }
      // 不足 K 个时，用 rank-0 重复补足；超过 K 个时截断。
      if (row.isEmpty) continue;
      while (row.length < candidatesPerColumn) {
        row.add(row.first);
      }
      if (row.length > candidatesPerColumn) {
        row.removeRange(candidatesPerColumn, row.length);
      }
      out.add(row);
    }
    return out;
  }

  List<List<int>> _emptyMatrix() => const [];

  /// 用户直接输入 12 个准确助记词时不依赖 LLM，保证未部署 AI 网关时仍可恢复登录。
  List<List<int>>? _tryParseExactWords(String input) {
    final words = input
        .split(RegExp(r'[\s,，、;；|/]+'))
        .map((word) => word.trim())
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    if (words.length != kStoryParserColumns) return null;

    final columns = <List<int>>[];
    for (final word in words) {
      final id = idByWord(word);
      if (id == null) return null;
      columns.add(List<int>.filled(candidatesPerColumn, id));
    }
    return columns;
  }
}
