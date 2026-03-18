import Fastify from "fastify";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const applyProxyConfig = vi.fn().mockResolvedValue({
  appliedMode: "manual",
  source: "manual",
  httpProxy: "http://127.0.0.1:7897",
  httpsProxy: "http://127.0.0.1:7897",
  noProxy: "localhost,127.0.0.1,::1",
  warnings: [],
});

vi.mock("../lib/net/proxy-runtime.js", () => ({
  applyProxyConfig,
}));

describe("preferences route proxy config", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
  });

  it("persists proxy settings and applies them to the current server process", async () => {
    const { default: preferencesRoute } = await import("../server/routes/preferences.js");
    const app = Fastify();
    const proxyConfig = {
      mode: "manual",
      manual: {
        httpProxy: "http://127.0.0.1:7897",
        httpsProxy: "http://127.0.0.1:7897",
        noProxy: "localhost,127.0.0.1,::1",
      },
    };

    const engine = {
      getSharedModels: vi.fn(() => ({})),
      getSearchConfig: vi.fn(() => ({ provider: null, api_key: null })),
      getUtilityApi: vi.fn(() => ({ provider: null, base_url: null, api_key: null })),
      getProxyConfig: vi.fn(() => proxyConfig),
      setSharedModels: vi.fn(),
      setSearchConfig: vi.fn(),
      setUtilityApi: vi.fn(),
      setProxyConfig: vi.fn(() => proxyConfig),
      syncModelsAndRefresh: vi.fn().mockResolvedValue(true),
    };

    await preferencesRoute(app, { engine });

    const res = await app.inject({
      method: "PUT",
      url: "/api/preferences/models",
      payload: {
        proxy: {
          mode: "manual",
          manual: {
            httpProxy: "http://127.0.0.1:7897",
          },
        },
      },
    });

    expect(res.statusCode).toBe(200);
    expect(engine.setProxyConfig).toHaveBeenCalledWith({
      mode: "manual",
      manual: {
        httpProxy: "http://127.0.0.1:7897",
      },
    });
    expect(applyProxyConfig).toHaveBeenCalledWith(proxyConfig);
    expect(engine.syncModelsAndRefresh).not.toHaveBeenCalled();

    await app.close();
  });
});
