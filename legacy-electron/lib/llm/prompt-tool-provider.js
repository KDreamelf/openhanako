import {
  AssistantMessageEventStream,
  getApiProvider,
  registerApiProvider,
  unregisterApiProviders,
} from "@mariozechner/pi-ai";
import { loadGlobalProviders } from "../memory/config-loader.js";

const PROMPT_TOOL_API_PREFIX = "hanako-prompt-tools";
const PROMPT_TOOL_SOURCE_ID = "hanako-prompt-tool-provider";
const TOOL_CALL_TAG_RE = /<tool_call>([\s\S]*?)<\/tool_call>/g;

export function normalizeToolFormat(value) {
  return value === "prompt" ? "prompt" : "native";
}

export function buildPromptToolApiName(providerName, baseApi) {
  return `${PROMPT_TOOL_API_PREFIX}/${encodeURIComponent(providerName)}/${encodeURIComponent(baseApi)}`;
}

export function isPromptToolApi(api) {
  return typeof api === "string" && api.startsWith(`${PROMPT_TOOL_API_PREFIX}/`);
}

export function parsePromptToolApiName(api) {
  if (!isPromptToolApi(api)) return null;
  const [, providerName, baseApi] = api.split("/");
  if (!providerName || !baseApi) return null;
  return {
    providerName: decodeURIComponent(providerName),
    baseApi: decodeURIComponent(baseApi),
  };
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function buildToolInstruction(tools) {
  if (!Array.isArray(tools) || tools.length === 0) return "";

  const renderedTools = tools.map((tool) => ({
    name: tool.name,
    description: tool.description || "",
    parameters: tool.parameters || { type: "object", properties: {} },
  }));

  return [
    "你可以通过提示词格式调用工具。",
    "当且仅当需要调用工具时，输出一个或多个 <tool_call> 标签。",
    "标签内部必须是 JSON，对象结构固定为：{\"name\":\"工具名\",\"arguments\":{...}}。",
    "不要使用 Markdown 代码块包裹工具调用 JSON。",
    "如果不需要调用工具，就直接正常回复，不要输出 <tool_call> 标签。",
    "可用工具如下：",
    JSON.stringify(renderedTools, null, 2),
  ].join("\n");
}

function serializeAssistantContent(content) {
  const parts = [];
  for (const block of content || []) {
    if (block.type === "text" && block.text) {
      parts.push(block.text);
      continue;
    }
    if (block.type === "toolCall") {
      parts.push(
        `<tool_call>${JSON.stringify({ name: block.name, arguments: block.arguments || {} })}</tool_call>`
      );
    }
  }
  return parts.join("\n");
}

function serializeToolResultMessage(message) {
  const text = (message.content || [])
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("\n")
    .trim();

  const prefix = `工具结果（${message.toolName}，${message.isError ? "失败" : "成功"}）`;
  const textContent = text ? `${prefix}：\n${text}` : `${prefix}。`;
  const images = (message.content || []).filter((block) => block.type === "image");

  if (images.length === 0) {
    return {
      role: "user",
      content: textContent,
      timestamp: message.timestamp,
    };
  }

  return {
    role: "user",
    content: [
      { type: "text", text: textContent },
      ...images,
    ],
    timestamp: message.timestamp,
  };
}

export function buildPromptToolContext(context) {
  return {
    systemPrompt: [context.systemPrompt || "", buildToolInstruction(context.tools)]
      .filter(Boolean)
      .join("\n\n"),
    messages: (context.messages || []).map((message) => {
      if (message.role === "user") return message;
      if (message.role === "assistant") {
        return {
          role: "assistant",
          content: serializeAssistantContent(message.content),
          timestamp: message.timestamp,
        };
      }
      if (message.role === "toolResult") {
        return serializeToolResultMessage(message);
      }
      return message;
    }),
  };
}

export function parsePromptToolResponseText(text) {
  const blocks = [];
  let cursor = 0;
  let toolCallIndex = 0;

  for (const match of text.matchAll(TOOL_CALL_TAG_RE)) {
    const fullMatch = match[0];
    const inner = match[1];
    const start = match.index ?? 0;
    const before = text.slice(cursor, start);
    if (before.length > 0) {
      blocks.push({ type: "text", text: before });
    }

    let parsed = null;
    try {
      parsed = JSON.parse(inner.trim());
    } catch {
      parsed = null;
    }

    const args = parsed && parsed.arguments === undefined
      ? {}
      : parsed?.arguments;

    if (
      parsed &&
      typeof parsed.name === "string" &&
      parsed.name.trim() &&
      isPlainObject(args)
    ) {
      toolCallIndex += 1;
      blocks.push({
        type: "toolCall",
        id: `prompt_tool_${toolCallIndex}`,
        name: parsed.name.trim(),
        arguments: args,
      });
    } else {
      blocks.push({ type: "text", text: fullMatch });
    }

    cursor = start + fullMatch.length;
  }

  const after = text.slice(cursor);
  if (after.length > 0) {
    blocks.push({ type: "text", text: after });
  }

  return blocks;
}

function emitParsedBlocks(stream, output, blocks) {
  for (let i = 0; i < blocks.length; i += 1) {
    const block = blocks[i];
    output.content.push(block);
    const contentIndex = output.content.length - 1;
    if (block.type === "text") {
      stream.push({ type: "text_start", contentIndex, partial: output });
      stream.push({
        type: "text_delta",
        contentIndex,
        delta: block.text,
        partial: output,
      });
      stream.push({
        type: "text_end",
        contentIndex,
        content: block.text,
        partial: output,
      });
      continue;
    }

    const json = JSON.stringify({ name: block.name, arguments: block.arguments });
    stream.push({ type: "toolcall_start", contentIndex, partial: output });
    stream.push({
      type: "toolcall_delta",
      contentIndex,
      delta: json,
      partial: output,
    });
    stream.push({
      type: "toolcall_end",
      contentIndex,
      toolCall: block,
      partial: output,
    });
  }
}

async function drainStream(stream) {
  for await (const _event of stream) {
    // 这里只负责消费底层事件，最终输出由 Hanako 自己重建。
  }
}

function collectAssistantText(message) {
  return (message.content || [])
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("");
}

function createPromptToolStream(baseApi) {
  return (model, context, options) => {
    const stream = new AssistantMessageEventStream();

    (async () => {
      const output = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: Date.now(),
      };

      try {
        const baseProvider = getApiProvider(baseApi);
        if (!baseProvider?.streamSimple) {
          throw new Error(`未找到基础 API provider: ${baseApi}`);
        }

        const baseModel = { ...model, api: baseApi };
        const promptContext = buildPromptToolContext(context);
        const baseStream = baseProvider.streamSimple(baseModel, promptContext, options);
        const resultPromise = baseStream.result();

        stream.push({ type: "start", partial: output });

        const [, finalMessage] = await Promise.all([
          drainStream(baseStream),
          resultPromise,
        ]);

        if (finalMessage.stopReason === "error" || finalMessage.stopReason === "aborted") {
          output.stopReason = finalMessage.stopReason;
          output.errorMessage = finalMessage.errorMessage;
          output.usage = finalMessage.usage;
          stream.push({ type: "error", reason: output.stopReason, error: output });
          stream.end(output);
          return;
        }

        output.usage = finalMessage.usage;
        const parsedBlocks = parsePromptToolResponseText(collectAssistantText(finalMessage));
        emitParsedBlocks(stream, output, parsedBlocks);
        output.stopReason = parsedBlocks.some((block) => block.type === "toolCall")
          ? "toolUse"
          : (finalMessage.stopReason === "length" ? "length" : "stop");

        stream.push({ type: "done", reason: output.stopReason, message: output });
        stream.end();
      } catch (error) {
        output.stopReason = options?.signal?.aborted ? "aborted" : "error";
        output.errorMessage = error instanceof Error ? error.message : String(error);
        stream.push({ type: "error", reason: output.stopReason, error: output });
        stream.end(output);
      }
    })();

    return stream;
  };
}

export function refreshPromptToolProviders() {
  unregisterApiProviders(PROMPT_TOOL_SOURCE_ID);

  const providers = loadGlobalProviders().providers || {};
  for (const [providerName, provider] of Object.entries(providers)) {
    if (normalizeToolFormat(provider?.tool_format) !== "prompt") continue;
    const baseApi = typeof provider?.api === "string" ? provider.api.trim() : "";
    if (!baseApi) continue;

    const api = buildPromptToolApiName(providerName, baseApi);
    const stream = createPromptToolStream(baseApi);
    registerApiProvider({ api, stream, streamSimple: stream }, PROMPT_TOOL_SOURCE_ID);
  }
}
