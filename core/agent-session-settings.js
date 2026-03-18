import { SettingsManager } from "@mariozechner/pi-coding-agent";

function cloneMergedSettings(cwd, agentDir) {
  const baseSettings = SettingsManager.create(cwd, agentDir);
  return structuredClone(baseSettings.settings || {});
}

function shouldPreferAutoTransport(model) {
  return model?.provider === "openai-codex";
}

/**
 * 为会话创建一个不落盘的 SettingsManager。
 *
 * Codex 在上游项目里验证过更稳的默认传输是 auto；这里只在用户仍停留
 * 在 SDK 默认的 sse 时做会话级覆盖，避免悄悄写回 settings.json。
 */
export function createAgentSessionSettings({ cwd, agentDir, model, compaction } = {}) {
  const settings = agentDir ? cloneMergedSettings(cwd, agentDir) : {};

  if (compaction) {
    settings.compaction = {
      ...(settings.compaction || {}),
      ...compaction,
    };
  }

  if (shouldPreferAutoTransport(model) && (!settings.transport || settings.transport === "sse")) {
    settings.transport = "auto";
  }

  return SettingsManager.inMemory(settings);
}
