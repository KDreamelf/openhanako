/**
 * win32-exec.js — Windows 平台的 bash 执行函数
 *
 * 这里明确只使用 Git for Windows 提供的 bash.exe。
 * 支持两种配置：
 * 1. smart      → 先从 PATH 查找 git，再检查常见 Git 安装目录
 * 2. custom_git → 用户手动指定 Git 安装目录
 */

import { existsSync } from "fs";
import { win32 as pathWin32 } from "path";
import { spawnSync } from "child_process";
import { spawnAndStream } from "./exec-helper.js";

const PROBE_TOKEN = "__hana_probe_ok__";
const SPAWN_ERROR_CODES = new Set(["ENOENT", "EACCES", "EPERM", "UNKNOWN"]);

export function normalizeBashPreference(preference) {
  return {
    mode: preference?.mode === "custom_git" ? "custom_git" : "smart",
    git_dir: typeof preference?.git_dir === "string" ? preference.git_dir.trim() : "",
  };
}

function getPathValue(env) {
  const pathKey = Object.keys(env || {}).find((key) => key.toLowerCase() === "path");
  return pathKey ? (env[pathKey] || "") : "";
}

function uniquePaths(paths) {
  const seen = new Set();
  const result = [];
  for (const value of paths) {
    if (!value) continue;
    const normalized = pathWin32.normalize(value);
    const key = normalized.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(normalized);
  }
  return result;
}

function getDefaultGitDirs(env) {
  return uniquePaths([
    env.ProgramFiles ? pathWin32.join(env.ProgramFiles, "Git") : "",
    env["ProgramFiles(x86)"] ? pathWin32.join(env["ProgramFiles(x86)"], "Git") : "",
    env.LOCALAPPDATA ? pathWin32.join(env.LOCALAPPDATA, "Programs", "Git") : "",
    env.USERPROFILE ? pathWin32.join(env.USERPROFILE, "scoop", "apps", "git", "current") : "",
    "C:\\Git",
    "D:\\Git",
  ]);
}

function buildGitRootsFromExecutable(gitExecutable) {
  const parent = pathWin32.dirname(gitExecutable);
  const grandParent = pathWin32.dirname(parent);
  const greatGrandParent = pathWin32.dirname(grandParent);
  return uniquePaths([grandParent, greatGrandParent]);
}

function findGitDirsFromPath(env, fileExists = existsSync) {
  const entries = getPathValue(env)
    .split(";")
    .map((entry) => entry.trim())
    .filter(Boolean);

  const gitDirs = [];
  for (const entry of entries) {
    for (const fileName of ["git.exe", "git.cmd"]) {
      const fullPath = pathWin32.join(entry, fileName);
      if (!fileExists(fullPath)) continue;
      gitDirs.push(...buildGitRootsFromExecutable(fullPath));
      break;
    }
  }

  return uniquePaths(gitDirs);
}

function resolveBashFromGitDir(gitDir, fileExists = existsSync) {
  const candidates = [
    pathWin32.join(gitDir, "bin", "bash.exe"),
    pathWin32.join(gitDir, "usr", "bin", "bash.exe"),
  ];

  for (const candidate of candidates) {
    if (!fileExists(candidate)) continue;
    return {
      shell: candidate,
      args: ["-c"],
      label: `Git Bash (${candidate})`,
      gitDir,
      bashPath: candidate,
    };
  }

  return null;
}

function buildSmartModeError() {
  return new Error(
    "[win32-exec] 未找到 Git Bash。\n" +
    "智能判断会先从 PATH 查找 git，再检查 Git for Windows 的常见安装目录。\n" +
    "你可能尚未安装 Windows 版 Git，bash 功能需要安装 Git for Windows。"
  );
}

export function listGitBashCandidates(preference, options = {}) {
  const env = options.env || process.env;
  const fileExists = options.existsSync || existsSync;
  const normalized = normalizeBashPreference(preference);

  if (normalized.mode === "custom_git") {
    if (!normalized.git_dir) {
      throw new Error("[win32-exec] 已选择自定义 Git 目录，但尚未指定目录。");
    }
    const candidate = resolveBashFromGitDir(normalized.git_dir, fileExists);
    if (!candidate) {
      throw new Error(
        `[win32-exec] 指定的 Git 目录中未找到 bash.exe：${normalized.git_dir}\n` +
        "请确认这是 Git for Windows 的安装目录。"
      );
    }
    return [{ ...candidate, source: "custom" }];
  }

  const pathGitDirs = findGitDirsFromPath(env, fileExists);
  const defaultGitDirs = getDefaultGitDirs(env);
  const orderedDirs = uniquePaths([...pathGitDirs, ...defaultGitDirs]);
  const candidates = [];

  for (const gitDir of orderedDirs) {
    const resolved = resolveBashFromGitDir(gitDir, fileExists);
    if (!resolved) continue;
    const isFromPath = pathGitDirs.some((entry) => entry.toLowerCase() === gitDir.toLowerCase());
    candidates.push({
      ...resolved,
      source: isFromPath ? "path" : "default",
    });
  }

  if (candidates.length === 0) {
    throw buildSmartModeError();
  }

  return candidates;
}

export function detectGitBash(preference, options = {}) {
  const normalized = normalizeBashPreference(preference);
  try {
    const [first] = listGitBashCandidates(normalized, options);
    return {
      mode: normalized.mode,
      found: true,
      source: first.source,
      git_dir: first.gitDir,
      bash_path: first.bashPath,
      message: "",
    };
  } catch (error) {
    return {
      mode: normalized.mode,
      found: false,
      source: "",
      git_dir: normalized.git_dir,
      bash_path: "",
      message: error instanceof Error ? error.message : String(error),
    };
  }
}

function probeShell(shell, args) {
  try {
    const result = spawnSync(shell, [...args, `echo ${PROBE_TOKEN}`], {
      encoding: "utf-8",
      timeout: 5000,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return result.status === 0 && (result.stdout || "").includes(PROBE_TOKEN);
  } catch {
    return false;
  }
}

function isShellSpawnError(err, shellPath) {
  if (!err || typeof err.code !== "string") return false;
  if (!SPAWN_ERROR_CODES.has(err.code)) return false;
  if (err.code === "ENOENT" && err.path && err.path !== shellPath) return false;
  return true;
}

function enrichError(retryErr, primaryShell, originalErr) {
  const msg = [
    "[win32-exec] 无法执行 shell 命令。",
    "",
    `首选 shell: ${primaryShell.label}`,
    `  错误: ${originalErr.message} (${originalErr.code || "unknown"})`,
    "",
    `降级也失败: ${retryErr.message}`,
    "",
    "建议：",
    "  1. 确认 Git for Windows 已正确安装",
    "  2. 确认 bash.exe 有执行权限",
    "  3. 如使用自定义 Git 目录，请检查目录是否指向 Git 安装根目录",
  ].join("\n");

  const enriched = new Error(msg);
  enriched.code = originalErr.code;
  return enriched;
}

function cleanShellEnv(baseEnv) {
  const env = { ...baseEnv };
  delete env.ELECTRON_RUN_AS_NODE;
  return env;
}

function getShellEnv() {
  const pathKey = Object.keys(process.env).find((key) => key.toLowerCase() === "path") ?? "PATH";
  return cleanShellEnv({ ...process.env, [pathKey]: process.env[pathKey] ?? "" });
}

export function createWin32Exec(options = {}) {
  const bashPreference = normalizeBashPreference(options.bashPreference);
  const detectionEnv = options.env || process.env;
  let cachedShell = null;

  const findAndCacheShell = (startAfter) => {
    if (cachedShell && !startAfter) return cachedShell;

    const candidates = listGitBashCandidates(bashPreference, { env: detectionEnv });
    let startIdx = 0;
    if (startAfter) {
      const idx = candidates.findIndex((candidate) => candidate.shell === startAfter);
      if (idx >= 0) startIdx = idx + 1;
    }

    const failed = [];
    for (let i = startIdx; i < candidates.length; i += 1) {
      const candidate = candidates[i];
      if (probeShell(candidate.shell, candidate.args)) {
        cachedShell = candidate;
        return candidate;
      }
      failed.push(candidate.label);
    }

    const details = failed.length
      ? `\n已尝试（probe 失败）：\n${failed.map((label) => `  - ${label}`).join("\n")}`
      : "";
    throw new Error(`${detectGitBash(bashPreference, { env: detectionEnv }).message}${details}`);
  };

  return async (command, cwd, { onData, signal, timeout, env }) => {
    const shellInfo = findAndCacheShell();
    const shellEnv = cleanShellEnv(env ?? getShellEnv());

    try {
      return await spawnAndStream(shellInfo.shell, [...shellInfo.args, command], {
        cwd,
        env: shellEnv,
        onData,
        signal,
        timeout,
      });
    } catch (err) {
      if (!isShellSpawnError(err, shellInfo.shell)) throw err;

      console.warn(`[win32-exec] Shell 执行失败 (${shellInfo.label}): ${err.code} ${err.message}，尝试降级…`);
      cachedShell = null;

      let fallback = null;
      try {
        fallback = findAndCacheShell(shellInfo.shell);
        console.warn(`[win32-exec] 降级到: ${fallback.label}`);
        return await spawnAndStream(fallback.shell, [...fallback.args, command], {
          cwd,
          env: shellEnv,
          onData,
          signal,
          timeout,
        });
      } catch (retryErr) {
        if (fallback && isShellSpawnError(retryErr, fallback.shell)) {
          throw enrichError(retryErr, shellInfo, err);
        }
        throw retryErr;
      }
    }
  };
}
