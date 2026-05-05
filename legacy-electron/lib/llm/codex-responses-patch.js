/**
 * codex-responses-patch.js
 *
 * 覆盖 Pi SDK 的 openai-codex-responses API provider，
 * 使其对非 JWT token（第三方 Codex 兼容供应商）不再因 accountId 提取失败而抛错。
 *
 * Pi SDK 原版 extractAccountId() 对所有请求都尝试把 apiKey 当 JWT 解码，
 * 提取 chatgpt_account_id，失败就抛 "Failed to extract accountId from token"。
 * 第三方供应商使用普通 API Key（sk-xxx），不是 JWT，必然失败。
 *
 * 本模块在 registerApiProvider 层覆盖原版，对非 JWT apiKey 构造一个假 JWT
 * 骗过 SDK 的 extractAccountId 检查，同时在 headers 里注入真正的 Authorization。
 */

import {
  registerApiProvider,
  getApiProvider,
} from "@mariozechner/pi-ai";

const PATCH_SOURCE_ID = "hanako-codex-responses-patch";

/**
 * 尝试从 JWT token 中提取 accountId，失败返回空字符串（而非抛错）
 */
function safeExtractAccountId(token) {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return "";
    const payload = JSON.parse(atob(parts[1]));
    const accountId = payload?.["https://api.openai.com/auth"]?.chatgpt_account_id;
    return accountId || "";
  } catch {
    return "";
  }
}

/**
 * 判断一个 apiKey 是否是含有 chatgpt_account_id 的真 OpenAI JWT
 */
function isOpenAIJwt(token) {
  if (!token || typeof token !== "string") return false;
  return !!safeExtractAccountId(token);
}

/**
 * 包装 stream 函数：对非 OpenAI JWT 的 apiKey，构造假 JWT 绕过 extractAccountId，
 * 同时通过 headers 覆盖传入真正的 Bearer token。
 */
function patchStreamFn(originalFn) {
  return (model, context, options) => {
    const apiKey = options?.apiKey || "";

    // 真正的 OpenAI JWT（含 chatgpt_account_id），走原版逻辑
    if (isOpenAIJwt(apiKey)) {
      return originalFn(model, context, options);
    }

    // 非 OpenAI JWT（普通 API Key 如 sk-xxx）：
    // 构造一个假 JWT，payload 里放一个占位 accountId，
    // 这样 SDK 内部的 extractAccountId 不会抛错。
    // 然后通过 headers 覆盖 Authorization 和 chatgpt-account-id，
    // 让真正的 apiKey 到达服务器。
    const fakePayload = Buffer.from(JSON.stringify({
      "https://api.openai.com/auth": { chatgpt_account_id: "third-party" }
    })).toString("base64");
    const fakeJwt = `fake.${fakePayload}.fake`;

    const patchedOptions = {
      ...options,
      apiKey: fakeJwt,
      headers: {
        ...(options?.headers || {}),
        "Authorization": `Bearer ${apiKey}`,
        "chatgpt-account-id": "",
      },
    };

    return originalFn(model, context, patchedOptions);
  };
}

/**
 * 注册覆盖后的 openai-codex-responses provider。
 * 必须在 Pi SDK 的 registerBuiltins() 之后调用。
 */
export function patchCodexResponsesProvider() {
  const original = getApiProvider("openai-codex-responses");
  if (!original) {
    console.warn("[codex-patch] openai-codex-responses provider not found, skipping patch");
    return;
  }

  // 注意：getApiProvider 返回的 stream/streamSimple 已经被 wrapStream 包装过，
  // 包装器会检查 model.api === api。但我们注册的是同名 api，所以没问题。
  // 但 wrapStream 里的闭包引用的是注册时的原始函数，我们需要拿到那个函数。
  // 由于 wrapStream 只是做了一个 api 检查，不影响实际逻辑，直接用就行。
  const patchedStream = patchStreamFn(original.stream);
  const patchedStreamSimple = patchStreamFn(original.streamSimple);

  registerApiProvider({
    api: "openai-codex-responses",
    stream: patchedStream,
    streamSimple: patchedStreamSimple,
  }, PATCH_SOURCE_ID);
}
