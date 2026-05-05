import Fastify from "fastify";
import { describe, expect, it, vi, beforeEach } from "vitest";

const applyProxyConfig = vi.fn().mockResolvedValue({
  appliedMode: "manual",
  source: "manual",
  httpProxy: "http://127.0.0.1:7897",
  httpsProxy: "http://127.0.0.1:7897",
  noProxy: "localhost,127.0.0.1,::1",
  warnings: [],
});

const detectGitBash = vi.fn();

vi.mock("../lib/net/proxy-runtime.js", () => ({
  applyProxyConfig,
}));

vi.mock("../lib/sandbox/win32-exec.js", () => ({
  detectGitBash,
}));

function createEngine(overrides = {}) {
  const proxyConfig = {
    mode: "manual",
    manual: {
      httpProxy: "http://127.0.0.1:7897",
      httpsProxy: "http://127.0.0.1:7897",
      noProxy: "localhost,127.0.0.1,::1",
    },
  };

  return {
    getSharedModels: vi.fn(() => ({})),
    getSearchConfig: vi.fn(() => ({ provider: null, api_key: null })),
    getUtilityApi: vi.fn(() => ({ provider: null, base_url: null, api_key: null })),
    getProxyConfig: vi.fn(() => proxyConfig),
    getBashConfig: vi.fn(() => ({ mode: "smart", git_dir: "" })),
    setSharedModels: vi.fn(),
    setSearchConfig: vi.fn(),
    setUtilityApi: vi.fn(),
    setProxyConfig: vi.fn(() => proxyConfig),
    setBashConfig: vi.fn((value) => value),
    syncModelsAndRefresh: vi.fn().mockResolvedValue(true),
    ...overrides,
  };
}

async function buildApp(engine) {
  const { default: preferencesRoute } = await import("../server/routes/preferences.js");
  const app = Fastify();
  await preferencesRoute(app, { engine });
  return app;
}

describe("preferences route proxy config", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    detectGitBash.mockReturnValue({
      mode: "smart",
      found: true,
      source: "path",
      git_dir: "C:\\Program Files\\Git",
      bash_path: "C:\\Program Files\\Git\\bin\\bash.exe",
      message: "",
    });
  });

  it("returns bash config and detection info", async () => {
    const bashConfig = { mode: "smart", git_dir: "" };
    const engine = createEngine({
      getBashConfig: vi.fn(() => bashConfig),
    });
    const app = await buildApp(engine);

    try {
      const res = await app.inject({
        method: "GET",
        url: "/api/preferences/models",
      });
      const data = res.json();

      expect(res.statusCode).toBe(200);
      expect(data.bash).toEqual(bashConfig);

      if (process.platform === "win32") {
        expect(detectGitBash).toHaveBeenCalledWith(bashConfig);
        expect(data.bash_detection).toEqual(detectGitBash.mock.results[0].value);
      } else {
        expect(detectGitBash).not.toHaveBeenCalled();
        expect(data.bash_detection).toBeNull();
      }
    } finally {
      await app.close();
    }
  });

  it("persists bash settings without triggering model sync", async () => {
    const engine = createEngine();
    const app = await buildApp(engine);
    const payload = {
      bash: {
        mode: "custom_git",
        git_dir: "C:\\Program Files\\Git",
      },
    };

    try {
      const res = await app.inject({
        method: "PUT",
        url: "/api/preferences/models",
        payload,
      });

      expect(res.statusCode).toBe(200);
      expect(engine.setBashConfig).toHaveBeenCalledWith(payload.bash);
      expect(applyProxyConfig).not.toHaveBeenCalled();
      expect(engine.syncModelsAndRefresh).not.toHaveBeenCalled();
    } finally {
      await app.close();
    }
  });

  it("persists proxy settings and applies them to the current server process", async () => {
    const engine = createEngine();
    const app = await buildApp(engine);
    const proxyConfig = {
      mode: "manual",
      manual: {
        httpProxy: "http://127.0.0.1:7897",
        httpsProxy: "http://127.0.0.1:7897",
        noProxy: "localhost,127.0.0.1,::1",
      },
    };

    try {
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
    } finally {
      await app.close();
    }
  });
});
