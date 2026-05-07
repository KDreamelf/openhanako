// lib/identity/story_composer.dart
//
// 故事编排器：把 12 个中文名词交给一个廉价 LLM，让它按固定顺序编一段
// 荒诞好记的记忆宫殿故事，强化每个名词作为有序核心意象。
//
// 与 MVP §10.5「生成期」对齐。
//
// 设计要点：
//   1. **本文件不直接持有 LLM 客户端**——只产出"系统提示词 + 用户输入"，
//      由调用方（OnboardingPage 或 IdentityRepository）传入一个
//      [StoryLlmCaller]。这样故事生成可以走任何模型，过渡期走现有 dio
//      Provider，未来走私有 AI 网关（MVP §2.5）。
//   2. **失败兜底**：LLM 调用失败时返回一个"无故事"结果，让用户依然能
//      看到 12 个原始词并自行记忆。账号生成不能因为 LLM 故障而阻塞。
//   3. **prompt 文案**：与 MVP §10.5 的故事生成约定保持一致，并额外强化
//      固定顺序与自然故事展示。如未来调整文案，需同步通知服务端做联调。

import 'package:meta/meta.dart';

/// 调用一次 LLM 的接口签名。
///
/// 参数：
///   - [systemPrompt] — 不含用户内容的固定系统提示词。
///   - [userPrompt]   — 用户实际给 LLM 的输入。
///   - [maxTokens]    — 期望最大输出 token 数（防止超长拖慢登录流程）。
///
/// 返回：
///   LLM 的纯文本响应（已去除前后空白）。失败时实现方应抛异常。
typedef StoryLlmCaller =
    Future<String> Function({
      required String systemPrompt,
      required String userPrompt,
      int? maxTokens,
    });

/// 故事生成器输出。
class StoryCompositionResult {
  StoryCompositionResult({
    required this.words,
    required this.story,
    required this.fallback,
  });

  /// 原始 12 词（与传入一致）。
  final List<String> words;

  /// LLM 生成的故事；失败时为空字符串。
  final String story;

  /// 是否走了兜底分支（true 表示 LLM 失败，故事为空）。
  final bool fallback;
}

class StoryComposer {
  StoryComposer({required this.caller});

  final StoryLlmCaller caller;

  /// 生成期：12 个中文名词 → 一段有序记忆宫殿故事。
  Future<StoryCompositionResult> compose(List<String> words) async {
    if (words.length != 12) {
      throw ArgumentError('故事生成需要恰好 12 个名词，收到 ${words.length}');
    }
    try {
      final story = await caller(
        systemPrompt: _systemPrompt,
        userPrompt: words.join('，'),
        maxTokens: 300,
      );
      final cleaned = _sanitize(story);
      if (cleaned.isEmpty) {
        return StoryCompositionResult(words: words, story: '', fallback: true);
      }
      return StoryCompositionResult(
        words: words,
        story: cleaned,
        fallback: false,
      );
    } catch (_) {
      // 这里有意吞掉异常——LLM 故障不能阻塞账号生成。
      // 调用方通过 fallback==true 知道走了兜底，UI 提示用户用原始词记忆。
      return StoryCompositionResult(words: words, story: '', fallback: true);
    }
  }

  /// 故事生成 prompt 系统词。
  /// 调整顺序/格式要求时，需同步恢复解析器与服务端公开故事通道联调。
  @visibleForTesting
  static const String systemPromptForTesting = _systemPrompt;
  static const String _systemPrompt = '''
你是一个记忆宫殿故事生成器。用户会给你 12 个有顺序的中文名词，请把它们编码成一段便于恢复顺序的自然故事。
核心要求：
必须严格按用户输入顺序写出 12 个名词，绝对不能调换、遗漏、替换或改成同义词。
不要输出任何编号、序号、数字锚点、列表符号，或“第一/第二/第几站”之类显式顺序标记。
故事必须是一条连续移动路径：每个名词都是一个固定场景锚点，并由上一个名词的动作自然引出下一个名词。
每个名词必须是对应场景的唯一核心实体；如果输入里有重复词，也要按位置重复写出。
情节要夸张、具象、容易形成记忆宫殿路径；靠动作和反常关系串联，不要堆砌额外实体名词。
控制在 120 字以内，输出一段故事正文；不要解释、Markdown、引号或列表前缀。
''';

  String _sanitize(String raw) {
    var s = raw.trim();
    if (s.startsWith('"') || s.startsWith('“')) {
      s = s.replaceFirst(RegExp(r'^["“]+'), '');
    }
    if (s.endsWith('"') || s.endsWith('”')) {
      s = s.replaceFirst(RegExp(r'["”]+$'), '');
    }
    return _stripOrderingMarkers(s).trim();
  }

  String _stripOrderingMarkers(String raw) {
    var s = raw.replaceAll(RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩⑪⑫]'), '');
    s = s.replaceAllMapped(
      RegExp(r'(^|[\s，。！？；、])[(（](?:1[0-2]|[1-9])[)）]\s*'),
      (match) => match.group(1) ?? '',
    );
    s = s.replaceAllMapped(
      RegExp(r'(^|[\s，。！？；、])(?:1[0-2]|[1-9])\s*[、.．:：)）-]\s*'),
      (match) => match.group(1) ?? '',
    );
    s = s.replaceAllMapped(
      RegExp(r'第[一二三四五六七八九十]{1,3}(?:个|段|幕|站|步|号)[、.．:：)）-]?\s*'),
      (_) => '',
    );
    return s;
  }
}
