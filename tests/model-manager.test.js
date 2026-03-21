import { describe, expect, it } from "vitest";
import { ModelManager } from "../core/model-manager.js";

describe("ModelManager provider-sensitive model lookup", () => {
  it("同名模型存在于多个 provider 时，优先使用显式指定的 provider", () => {
    const manager = new ModelManager({ hanakoHome: "test-home" });
    manager._availableModels = [
      { id: "gpt-5.4", provider: "openai", name: "GPT 5.4" },
      { id: "gpt-5.4", provider: "openai-codex", name: "GPT 5.4" },
    ];

    const resolved = manager.resolveConfiguredModel("gpt-5.4", {
      api: { provider: "openai-codex" },
    });

    expect(resolved?.provider).toBe("openai-codex");
  });

  it("当首选 provider 不可用时，会回退到同名模型的其他可用 provider", () => {
    const manager = new ModelManager({ hanakoHome: "test-home" });
    manager._availableModels = [
      { id: "gpt-5.4", provider: "openai", name: "GPT 5.4" },
    ];

    const resolved = manager.findAvailableModel("gpt-5.4", "openai-codex");

    expect(resolved?.provider).toBe("openai");
  });
});
