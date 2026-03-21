import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";

vi.mock("../desktop/src/react/settings/store", () => ({
  useSettingsStore: {
    getState: () => ({
      serverPort: "3210",
      serverToken: "test-token",
    }),
  },
}));

describe("settings hanaFetch", () => {
  const nativeFetch = globalThis.fetch;

  beforeEach(() => {
    vi.restoreAllMocks();
  });

  afterEach(() => {
    globalThis.fetch = nativeFetch;
  });

  it("prefers server error details over generic HTTP status text", async () => {
    const { hanaFetch } = await import("../desktop/src/react/settings/api.ts");

    globalThis.fetch = vi.fn(async () => new Response(
      JSON.stringify({ error: "认证文件缺少 access_token 或 refresh_token" }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      },
    ));

    await expect(hanaFetch("/api/auth/oauth/import")).rejects.toThrow(
      "hanaFetch /api/auth/oauth/import: 认证文件缺少 access_token 或 refresh_token",
    );
  });
});
