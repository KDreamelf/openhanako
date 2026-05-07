import 'package:flutter_test/flutter_test.dart';
import 'package:hanako/llm/tool_format/prompt_tool.dart';

void main() {
  test('把 think 标签解析为思考事件而不是正文', () {
    final parser = PromptToolStreamParser();

    final events = parser.push('<think>内部推理</think>正文');

    expect(events, hasLength(2));
    expect(events[0], isA<PromptToolThinkDelta>());
    expect((events[0] as PromptToolThinkDelta).text, '内部推理');
    expect(events[1], isA<PromptToolTextDelta>());
    expect((events[1] as PromptToolTextDelta).text, '正文');
  });

  test('兼容 thinking 标签', () {
    final parser = PromptToolStreamParser();

    final events = parser.push('<thinking>内部推理</thinking>正文');

    expect(events, hasLength(2));
    expect(events[0], isA<PromptToolThinkDelta>());
    expect((events[0] as PromptToolThinkDelta).text, '内部推理');
    expect(events[1], isA<PromptToolTextDelta>());
    expect((events[1] as PromptToolTextDelta).text, '正文');
  });

  test('think 闭合标签跨 chunk 时不泄露到正文', () {
    final parser = PromptToolStreamParser();

    final first = parser.push('<think>内部推理</thi');
    final second = parser.push('nk>正文');

    expect(first, hasLength(1));
    expect(first.single, isA<PromptToolThinkDelta>());
    expect((first.single as PromptToolThinkDelta).text, '内部推理');
    expect(second, hasLength(1));
    expect(second.single, isA<PromptToolTextDelta>());
    expect((second.single as PromptToolTextDelta).text, '正文');
  });

  test('解析 prompt tool 调用', () {
    final parser = PromptToolStreamParser();

    final events = parser.push(
      '<tool_call>{"name":"local_environment","arguments":{}}</tool_call>',
    );

    expect(events, hasLength(1));
    final call = events.single as PromptToolCallParsed;
    expect(call.name, 'local_environment');
    expect(call.argumentsJson, '{}');
  });
}
