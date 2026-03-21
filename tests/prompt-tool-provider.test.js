import { describe, expect, it } from "vitest";
import { parsePromptToolResponseText } from "../lib/llm/prompt-tool-provider.js";

describe("prompt-tool-provider", () => {
  it("解析单个 tool_call 标签", () => {
    const blocks = parsePromptToolResponseText(
      '<tool_call>{"name":"read","arguments":{"file_path":"a.txt"}}</tool_call>'
    );

    expect(blocks).toEqual([
      {
        type: "toolCall",
        id: "prompt_tool_1",
        name: "read",
        arguments: { file_path: "a.txt" },
      },
    ]);
  });

  it("支持文本与 tool_call 混合输出", () => {
    const blocks = parsePromptToolResponseText(
      '先看看文件。\n<tool_call>{"name":"read","arguments":{"file_path":"a.txt"}}</tool_call>\n等结果回来再继续。'
    );

    expect(blocks).toEqual([
      { type: "text", text: "先看看文件。\n" },
      {
        type: "toolCall",
        id: "prompt_tool_1",
        name: "read",
        arguments: { file_path: "a.txt" },
      },
      { type: "text", text: "\n等结果回来再继续。" },
    ]);
  });

  it("非法 JSON 会回退为普通文本", () => {
    const raw = '<tool_call>{"name":"read","arguments":}</tool_call>';
    const blocks = parsePromptToolResponseText(raw);

    expect(blocks).toEqual([{ type: "text", text: raw }]);
  });
});
