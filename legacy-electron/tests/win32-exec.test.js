import { describe, expect, it } from "vitest";
import { detectGitBash, listGitBashCandidates } from "../lib/sandbox/win32-exec.js";

describe("win32-exec Git Bash detection", () => {
  it("smart 模式优先使用 PATH 中的 git", () => {
    const existing = new Set([
      "D:\\PortableGit\\cmd\\git.exe",
      "D:\\PortableGit\\bin\\bash.exe",
      "C:\\Program Files\\Git\\bin\\bash.exe",
    ]);

    const candidates = listGitBashCandidates(
      { mode: "smart" },
      {
        env: {
          PATH: "D:\\PortableGit\\cmd;C:\\Windows\\System32",
          ProgramFiles: "C:\\Program Files",
        },
        existsSync: (target) => existing.has(target),
      },
    );

    expect(candidates[0].source).toBe("path");
    expect(candidates[0].gitDir).toBe("D:\\PortableGit");
    expect(candidates[0].bashPath).toBe("D:\\PortableGit\\bin\\bash.exe");
  });

  it("smart 模式找不到 Git 时给出明确提示", () => {
    const detection = detectGitBash(
      { mode: "smart" },
      {
        env: { PATH: "", ProgramFiles: "C:\\Program Files" },
        existsSync: () => false,
      },
    );

    expect(detection.found).toBe(false);
    expect(detection.message).toContain("未找到 Git Bash");
    expect(detection.message).toContain("Windows 版 Git");
  });
});
