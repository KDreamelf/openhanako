import fs from "fs";
import path from "path";
import vm from "vm";
import { fileURLToPath } from "url";
import { describe, expect, it } from "vitest";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const onboardingHtmlPath = path.join(__dirname, "..", "desktop", "src", "onboarding.html");
const onboardingJsPath = path.join(__dirname, "..", "desktop", "src", "onboarding.js");
const runtimeCreatedIds = new Set(["obErrorToast", "obFatalError", "obFatalErrorDetail"]);

function extractHtmlIds(html) {
  return new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]));
}

function extractJsDomIds(source) {
  const ids = new Set();
  const patterns = [
    /\$\("#([^"]+)"\)/g,
    /\$\('#([^']+)'\)/g,
    /document\.getElementById\("([^"]+)"\)/g,
    /document\.getElementById\('([^']+)'\)/g,
  ];

  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) ids.add(match[1]);
  }
  return ids;
}

describe("onboarding 页面冒烟检查", () => {
  const html = fs.readFileSync(onboardingHtmlPath, "utf-8");
  const source = fs.readFileSync(onboardingJsPath, "utf-8");

  it("脚本语法有效", () => {
    expect(() => new vm.Script(source)).not.toThrow();
  });

  it("脚本引用的 DOM id 都存在于页面中", () => {
    const htmlIds = extractHtmlIds(html);
    const jsIds = extractJsDomIds(source);
    const missing = [...jsIds]
      .filter((id) => !htmlIds.has(id) && !runtimeCreatedIds.has(id))
      .sort();

    expect(missing).toEqual([]);
  });
});
