import fs from "fs";
import os from "os";
import path from "path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { syncFavoritesToModelsJson } from "../core/sync-favorites.js";

const tmpRoot = path.join(os.tmpdir(), `hana-test-sync-favorites-${Date.now()}`);
const configPath = path.join(tmpRoot, "config.yaml");

function writeConfig() {
  fs.writeFileSync(
    configPath,
    [
      "models:",
      "  favorites:",
      "    - qwen-plus",
      "providers:",
      "  dashscope:",
      '    base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1"',
      '    api_key: "sk-test"',
      '    api: "openai-completions"',
      "    models:",
      "      - qwen-plus",
      "",
    ].join("\n"),
    "utf-8",
  );
}

beforeEach(() => {
  fs.mkdirSync(tmpRoot, { recursive: true });
  writeConfig();
});

afterEach(() => {
  delete process.env.HANA_HOME;
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

describe("syncFavoritesToModelsJson", () => {
  it("fallback 路径会跟随 HANA_HOME", () => {
    const hanakoHome = path.join(tmpRoot, "hana-home");
    process.env.HANA_HOME = hanakoHome;
    fs.mkdirSync(hanakoHome, { recursive: true });

    const changed = syncFavoritesToModelsJson(configPath);
    const modelsPath = path.join(hanakoHome, "models.json");

    expect(changed).toBe(true);
    expect(fs.existsSync(modelsPath)).toBe(true);
  });

  it("显式传入 modelsJsonPath 时优先使用传入路径", () => {
    process.env.HANA_HOME = path.join(tmpRoot, "unused-home");
    const modelsPath = path.join(tmpRoot, "custom-models.json");

    const changed = syncFavoritesToModelsJson(configPath, { modelsJsonPath: modelsPath });

    expect(changed).toBe(true);
    expect(fs.existsSync(modelsPath)).toBe(true);
  });

  it("provider 缺少 api 协议时直接报错", () => {
    fs.writeFileSync(
      configPath,
      [
        "models:",
        "  favorites:",
        "    - qwen-plus",
        "providers:",
        "  dashscope:",
        '    base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1"',
        '    api_key: "sk-test"',
        "    models:",
        "      - qwen-plus",
        "",
      ].join("\n"),
      "utf-8",
    );

    expect(() => syncFavoritesToModelsJson(configPath, {
      modelsJsonPath: path.join(tmpRoot, "custom-models.json"),
    })).toThrow('provider "dashscope" 缺少 API 协议配置');
  });

  it("显式传入空 favorites 时不会回退到 config 里的旧 favorites", () => {
    const modelsPath = path.join(tmpRoot, "custom-models.json");
    fs.writeFileSync(modelsPath, JSON.stringify({
      providers: {
        dashscope: {
          baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
          api: "openai-completions",
          apiKey: "sk-test",
          models: [{ id: "qwen-plus", name: "Qwen Plus" }],
        },
      },
    }, null, 2), "utf-8");

    const changed = syncFavoritesToModelsJson(configPath, {
      modelsJsonPath: modelsPath,
      favorites: [],
    });

    const result = JSON.parse(fs.readFileSync(modelsPath, "utf-8"));
    expect(changed).toBe(true);
    expect(result).toEqual({ providers: {} });
  });

  it("同步时会保留已有模型展示名并保持原始 id", () => {
    const modelsPath = path.join(tmpRoot, "custom-models.json");
    fs.writeFileSync(modelsPath, JSON.stringify({
      providers: {
        dashscope: {
          baseUrl: "https://dashscope.aliyuncs.com/compatible-mode/v1",
          api: "openai-completions",
          apiKey: "sk-test",
          models: [{ id: "qwen-plus", name: "Qwen Plus" }],
        },
      },
    }, null, 2), "utf-8");

    const changed = syncFavoritesToModelsJson(configPath, { modelsJsonPath: modelsPath });
    const result = JSON.parse(fs.readFileSync(modelsPath, "utf-8"));

    expect(changed).toBe(false);
    expect(result.providers.dashscope.models[0].id).toBe("qwen-plus");
    expect(result.providers.dashscope.models[0].name).toBe("Qwen Plus");
  });

  it("当前配置已经切到 OAuth provider 时，不会继续沿用旧 models.json 的陈旧 provider 归属", () => {
    fs.writeFileSync(
      configPath,
      [
        "api:",
        '  provider: "openai-codex"',
        "models:",
        '  chat: "gpt-5.4"',
        "  favorites:",
        '    - "gpt-5.4"',
        "providers:",
        "  openai-codex:",
        '    base_url: "https://chatgpt.com/backend-api"',
        '    api_key: "oauth-token"',
        '    api: "openai-codex-responses"',
        "    models:",
        '      - "gpt-5.4"',
        "",
      ].join("\n"),
      "utf-8",
    );

    const modelsPath = path.join(tmpRoot, "custom-models.json");
    fs.writeFileSync(modelsPath, JSON.stringify({
      providers: {
        openai: {
          baseUrl: "https://api.openai.com/v1",
          api: "openai-completions",
          apiKey: "sk-stale",
          models: [{ id: "gpt-5.4", name: "GPT 5.4" }],
        },
      },
    }, null, 2), "utf-8");

    const changed = syncFavoritesToModelsJson(configPath, { modelsJsonPath: modelsPath });
    const result = JSON.parse(fs.readFileSync(modelsPath, "utf-8"));

    expect(changed).toBe(true);
    expect(Object.keys(result.providers)).toEqual(["openai-codex"]);
    expect(result.providers["openai-codex"].models[0].id).toBe("gpt-5.4");
  });
});
