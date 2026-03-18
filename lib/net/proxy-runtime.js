import { execFileSync } from "node:child_process";
import { Agent, EnvHttpProxyAgent, setGlobalDispatcher } from "undici";

export const DEFAULT_PROXY_MODE = "system";
export const LOCAL_NO_PROXY = "localhost,127.0.0.1,::1";

const VALID_PROXY_MODES = new Set(["none", "system", "manual"]);
const LOCAL_NO_PROXY_TOKENS = ["localhost", "127.0.0.1", "::1"];

let activeDispatcher = null;

function trimText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function splitProxyList(value) {
  return String(value || "")
    .split(/[,\s;]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function mergeNoProxy(...values) {
  const merged = [];
  for (const value of values) {
    for (const item of splitProxyList(value)) {
      if (!merged.some((existing) => existing.toLowerCase() === item.toLowerCase())) {
        merged.push(item);
      }
    }
  }
  return merged.join(",");
}

function ensureProxyUri(value, fallbackScheme = "http") {
  const text = trimText(value);
  if (!text) return "";
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) return text;
  return `${fallbackScheme}://${text}`;
}

function readWindowsInternetSetting(name) {
  try {
    const stdout = execFileSync(
      "reg",
      ["query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", name],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        windowsHide: true,
      },
    );
    const lines = stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    const line = lines.find((entry) => entry.toLowerCase().startsWith(name.toLowerCase()));
    if (!line) return "";
    const parts = line.split(/\s{2,}/).filter(Boolean);
    return parts[2] || "";
  } catch {
    return "";
  }
}

export function getDefaultProxyConfig() {
  return {
    mode: DEFAULT_PROXY_MODE,
    manual: {
      httpProxy: "",
      httpsProxy: "",
      noProxy: "",
    },
  };
}

export function normalizeProxyConfig(input) {
  const defaults = getDefaultProxyConfig();
  const raw = input && typeof input === "object" ? input : {};
  const mode = VALID_PROXY_MODES.has(raw.mode) ? raw.mode : defaults.mode;
  const manual = raw.manual && typeof raw.manual === "object" ? raw.manual : {};

  return {
    mode,
    manual: {
      httpProxy: trimText(manual.httpProxy),
      httpsProxy: trimText(manual.httpsProxy),
      noProxy: trimText(manual.noProxy),
    },
  };
}

export function mergeProxyConfig(current, partial) {
  const previous = normalizeProxyConfig(current);
  const next = partial && typeof partial === "object" ? partial : {};
  const nextManual = next.manual && typeof next.manual === "object" ? next.manual : {};

  return normalizeProxyConfig({
    ...previous,
    ...next,
    manual: {
      ...previous.manual,
      ...nextManual,
    },
  });
}

export function parseWindowsProxyServer(rawValue) {
  const raw = trimText(rawValue);
  if (!raw) {
    return { httpProxy: "", httpsProxy: "" };
  }

  if (!raw.includes("=")) {
    const shared = ensureProxyUri(raw, "http");
    return {
      httpProxy: shared,
      httpsProxy: shared,
    };
  }

  const entries = Object.create(null);
  for (const part of raw.split(";")) {
    const [key, value] = part.split("=", 2);
    const normalizedKey = trimText(key).toLowerCase();
    const normalizedValue = trimText(value);
    if (!normalizedKey || !normalizedValue) continue;
    entries[normalizedKey] = normalizedValue;
  }

  const httpProxy = ensureProxyUri(entries.http || entries.socks || "", entries.socks ? "socks" : "http");
  const httpsProxy = ensureProxyUri(entries.https || entries.http || entries.socks || "", entries.socks ? "socks" : "http");

  return {
    httpProxy,
    httpsProxy,
  };
}

export function parseWindowsProxyOverride(rawValue) {
  const items = splitProxyList(rawValue);
  const results = [];

  for (const item of items) {
    if (item === "<local>") {
      results.push("*.local", ...LOCAL_NO_PROXY_TOKENS);
      continue;
    }
    results.push(item);
  }

  return mergeNoProxy(results.join(","), LOCAL_NO_PROXY);
}

export function resolveWindowsSystemProxy(reader = readWindowsInternetSetting) {
  const proxyEnabledRaw = trimText(reader("ProxyEnable"));
  const proxyServer = trimText(reader("ProxyServer"));
  const proxyOverride = trimText(reader("ProxyOverride"));
  const autoConfigUrl = trimText(reader("AutoConfigURL"));
  const isEnabled = !!proxyEnabledRaw && !/^0x0$|^0$/i.test(proxyEnabledRaw);
  const manual = isEnabled ? parseWindowsProxyServer(proxyServer) : { httpProxy: "", httpsProxy: "" };
  const warnings = [];

  if (autoConfigUrl) {
    warnings.push("检测到系统 PAC/自动代理脚本，当前版本暂不直接解析 PAC。");
  }

  return {
    httpProxy: manual.httpProxy,
    httpsProxy: manual.httpsProxy,
    noProxy: parseWindowsProxyOverride(proxyOverride),
    autoConfigUrl,
    source:
      manual.httpProxy || manual.httpsProxy
        ? "windows-system"
        : autoConfigUrl
          ? "windows-system-pac"
          : "windows-direct",
    warnings,
  };
}

export function resolveSystemProxyConfig({ platform = process.platform, env = process.env } = {}) {
  if (platform === "win32") {
    return resolveWindowsSystemProxy();
  }

  const httpProxy = trimText(env.HTTP_PROXY || env.http_proxy || env.ALL_PROXY || env.all_proxy);
  const httpsProxy = trimText(env.HTTPS_PROXY || env.https_proxy || httpProxy);
  const noProxy = mergeNoProxy(env.NO_PROXY || env.no_proxy, LOCAL_NO_PROXY);

  return {
    httpProxy,
    httpsProxy,
    noProxy,
    autoConfigUrl: "",
    source: httpProxy || httpsProxy ? "env" : "direct",
    warnings: [],
  };
}

function buildManualProxyRuntime(config) {
  return {
    httpProxy: ensureProxyUri(config.manual.httpProxy, "http"),
    httpsProxy: ensureProxyUri(config.manual.httpsProxy, "http"),
    noProxy: mergeNoProxy(config.manual.noProxy, LOCAL_NO_PROXY),
    autoConfigUrl: "",
    source: "manual",
    warnings: [],
  };
}

function buildDirectRuntime(source = "direct") {
  return {
    httpProxy: "",
    httpsProxy: "",
    noProxy: LOCAL_NO_PROXY,
    autoConfigUrl: "",
    source,
    warnings: [],
  };
}

export async function applyProxyConfig(input, opts = {}) {
  const config = normalizeProxyConfig(input);
  const runtime =
    config.mode === "manual"
      ? buildManualProxyRuntime(config)
      : config.mode === "system"
        ? resolveSystemProxyConfig(opts)
        : buildDirectRuntime("disabled");

  const noProxy = mergeNoProxy(runtime.noProxy, LOCAL_NO_PROXY);
  let dispatcher = null;
  let appliedMode = config.mode;

  if (config.mode === "none") {
    dispatcher = new Agent();
  } else if (runtime.httpProxy || runtime.httpsProxy) {
    dispatcher = new EnvHttpProxyAgent({
      httpProxy: runtime.httpProxy || undefined,
      httpsProxy: runtime.httpsProxy || undefined,
      noProxy: noProxy || undefined,
    });
  } else {
    dispatcher = new Agent();
    appliedMode = "none";
  }

  const previousDispatcher = activeDispatcher;
  activeDispatcher = dispatcher;
  setGlobalDispatcher(dispatcher);

  if (previousDispatcher && previousDispatcher !== dispatcher && typeof previousDispatcher.close === "function") {
    try {
      await previousDispatcher.close();
    } catch {
      // Ignore close errors on dispatcher replacement.
    }
  }

  return {
    config,
    appliedMode,
    source: runtime.source,
    httpProxy: runtime.httpProxy,
    httpsProxy: runtime.httpsProxy,
    noProxy,
    autoConfigUrl: runtime.autoConfigUrl,
    warnings: [...runtime.warnings],
  };
}

export function describeAppliedProxy(result) {
  if (!result) return "proxy=unknown";

  if (result.appliedMode === "none") {
    return `proxy=direct (requested=${result.config?.mode || "none"}, source=${result.source || "direct"})`;
  }

  const endpoints = [];
  if (result.httpProxy) endpoints.push(`http=${result.httpProxy}`);
  if (result.httpsProxy) endpoints.push(`https=${result.httpsProxy}`);

  return `proxy=${result.appliedMode} source=${result.source || "unknown"} ${endpoints.join(" ")}`.trim();
}
