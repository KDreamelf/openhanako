import fs from "fs";
import os from "os";
import path from "path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ensureFirstRun } from "../core/first-run.js";

function createTempFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "hanako-first-run-"));
  const productRoot = path.join(root, "product");
  const productDir = path.join(productRoot, "lib");
  const skillsDir = path.join(productRoot, "skills2set", "demo-skill");
  const hanakoHome = path.join(root, "home");

  fs.mkdirSync(productDir, { recursive: true });
  fs.mkdirSync(skillsDir, { recursive: true });

  fs.writeFileSync(path.join(productDir, "config.example.yaml"), "name: Hanako\n", "utf-8");
  fs.writeFileSync(path.join(productDir, "identity.example.md"), "Hello {{agentName}} {{userName}}\n", "utf-8");
  fs.writeFileSync(path.join(productDir, "ishiki.example.md"), "ishiki\n", "utf-8");

  fs.writeFileSync(path.join(skillsDir, "SKILL.md"), "# Demo Skill\n", "utf-8");
  fs.writeFileSync(path.join(skillsDir, "ok.txt"), "ok\n", "utf-8");
  fs.writeFileSync(path.join(skillsDir, "broken.txt"), "broken\n", "utf-8");

  return { root, productDir, hanakoHome };
}

describe("ensureFirstRun", () => {
  let fixtureRoot = null;

  afterEach(() => {
    vi.restoreAllMocks();
    if (fixtureRoot) fs.rmSync(fixtureRoot, { recursive: true, force: true });
    fixtureRoot = null;
  });

  it("单个 skill 文件复制失败时仍继续启动", () => {
    const fixture = createTempFixture();
    fixtureRoot = fixture.root;

    const realCopyFileSync = fs.copyFileSync.bind(fs);
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(fs, "copyFileSync").mockImplementation((src, dst, mode) => {
      if (String(src).endsWith(`${path.sep}demo-skill${path.sep}broken.txt`)) {
        const err = new Error("EPERM: file is locked");
        err.code = "EPERM";
        throw err;
      }
      return realCopyFileSync(src, dst, mode);
    });

    expect(() => ensureFirstRun(fixture.hanakoHome, fixture.productDir)).not.toThrow();
    expect(fs.existsSync(path.join(fixture.hanakoHome, "skills", "demo-skill", "ok.txt"))).toBe(true);
    expect(fs.existsSync(path.join(fixture.hanakoHome, "skills", "demo-skill", "broken.txt"))).toBe(false);
    expect(fs.existsSync(path.join(fixture.hanakoHome, "user", "preferences.json"))).toBe(true);
    expect(warnSpy).toHaveBeenCalled();
  });
});
