import { describe, expect, it } from "vitest";

import {
  LOCAL_NO_PROXY,
  getDefaultProxyConfig,
  mergeProxyConfig,
  normalizeProxyConfig,
  parseWindowsProxyOverride,
  parseWindowsProxyServer,
  resolveWindowsSystemProxy,
} from "../lib/net/proxy-runtime.js";

describe("proxy runtime helpers", () => {
  it("normalizes missing proxy config to system mode", () => {
    expect(normalizeProxyConfig(null)).toEqual(getDefaultProxyConfig());
  });

  it("merges partial proxy updates while preserving manual fields", () => {
    const merged = mergeProxyConfig(
      {
        mode: "manual",
        manual: {
          httpProxy: " http://127.0.0.1:7897 ",
          httpsProxy: "",
          noProxy: "example.com",
        },
      },
      {
        mode: "system",
        manual: {
          httpsProxy: " https://proxy.local:8443 ",
        },
      },
    );

    expect(merged).toEqual({
      mode: "system",
      manual: {
        httpProxy: "http://127.0.0.1:7897",
        httpsProxy: "https://proxy.local:8443",
        noProxy: "example.com",
      },
    });
  });

  it("parses a shared Windows proxy server for both HTTP and HTTPS", () => {
    expect(parseWindowsProxyServer("127.0.0.1:7897")).toEqual({
      httpProxy: "http://127.0.0.1:7897",
      httpsProxy: "http://127.0.0.1:7897",
    });
  });

  it("parses scheme-specific Windows proxy server entries", () => {
    expect(parseWindowsProxyServer("http=127.0.0.1:7897;https=127.0.0.1:7898")).toEqual({
      httpProxy: "http://127.0.0.1:7897",
      httpsProxy: "http://127.0.0.1:7898",
    });
  });

  it("expands Windows proxy override local placeholders", () => {
    const noProxy = parseWindowsProxyOverride("localhost;*.internal;<local>;127.0.0.1");

    expect(noProxy).toContain("*.internal");
    expect(noProxy).toContain("*.local");
    expect(noProxy).toContain("localhost");
    expect(noProxy).toContain("127.0.0.1");
    expect(noProxy).toContain("::1");
  });

  it("resolves Windows system proxy and reports PAC warnings", () => {
    const values = {
      ProxyEnable: "0x1",
      ProxyServer: "http=127.0.0.1:7897;https=127.0.0.1:7898",
      ProxyOverride: "localhost;example.com",
      AutoConfigURL: "http://wpad.local/proxy.pac",
    };

    const resolved = resolveWindowsSystemProxy((key) => values[key] || "");

    expect(resolved.httpProxy).toBe("http://127.0.0.1:7897");
    expect(resolved.httpsProxy).toBe("http://127.0.0.1:7898");
    expect(resolved.noProxy).toContain("example.com");
    expect(resolved.noProxy).toContain(LOCAL_NO_PROXY.split(",")[0]);
    expect(resolved.autoConfigUrl).toBe("http://wpad.local/proxy.pac");
    expect(resolved.warnings[0]).toContain("PAC");
  });
});
