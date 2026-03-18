import { beforeEach, describe, expect, it, vi } from "vitest";

const { settingsManagerCreateMock, settingsManagerInMemoryMock } = vi.hoisted(() => ({
  settingsManagerCreateMock: vi.fn(),
  settingsManagerInMemoryMock: vi.fn(),
}));

vi.mock("@mariozechner/pi-coding-agent", () => ({
  SettingsManager: {
    create: settingsManagerCreateMock,
    inMemory: settingsManagerInMemoryMock,
  },
}));

import { createAgentSessionSettings } from "../core/agent-session-settings.js";

describe("createAgentSessionSettings", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    settingsManagerCreateMock.mockReturnValue({ settings: {} });
    settingsManagerInMemoryMock.mockImplementation((settings) => ({
      settings,
      getTransport: () => settings.transport ?? "sse",
    }));
  });

  it("switches openai-codex from default sse to auto", () => {
    settingsManagerCreateMock.mockReturnValue({ settings: { transport: "sse" } });

    const settings = createAgentSessionSettings({
      cwd: "/tmp/workspace",
      agentDir: "/tmp/agent",
      model: { provider: "openai-codex" },
    });

    expect(settingsManagerCreateMock).toHaveBeenCalledWith("/tmp/workspace", "/tmp/agent");
    expect(settingsManagerInMemoryMock).toHaveBeenCalledWith({ transport: "auto" });
    expect(settings.getTransport()).toBe("auto");
  });

  it("keeps explicit non-sse transport choices intact", () => {
    settingsManagerCreateMock.mockReturnValue({ settings: { transport: "websocket" } });

    const settings = createAgentSessionSettings({
      cwd: "/tmp/workspace",
      agentDir: "/tmp/agent",
      model: { provider: "openai-codex" },
    });

    expect(settingsManagerInMemoryMock).toHaveBeenCalledWith({ transport: "websocket" });
    expect(settings.getTransport()).toBe("websocket");
  });

  it("merges compaction overrides for in-memory sessions", () => {
    const settings = createAgentSessionSettings({
      model: { provider: "openai-codex" },
      compaction: { enabled: true, keepRecentTokens: 20000 },
    });

    expect(settingsManagerInMemoryMock).toHaveBeenCalledWith({
      transport: "auto",
      compaction: {
        enabled: true,
        keepRecentTokens: 20000,
      },
    });
    expect(settings.settings.compaction.keepRecentTokens).toBe(20000);
  });
});
