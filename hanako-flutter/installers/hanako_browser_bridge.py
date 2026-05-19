import base64
import json
import os
import re
import sys
import time
import traceback
from pathlib import Path
from urllib.parse import urlparse


class BrowserBridge:
    def __init__(self, config_path):
        self.config_path = Path(config_path)
        self.config = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.camoufox_ctx = None
        self.browser = None
        self.page = None

    def start(self):
        if self.page is not None:
            return self.status("Camoufox browser already started")

        configured_executable = self.config.get("browserExecutable")
        executable = (
            configured_executable
            if configured_executable and Path(str(configured_executable)).exists()
            else self._find_browser_executable()
        )
        if not executable or not Path(executable).exists():
            return {
                "ok": False,
                "error": "browser_executable_missing",
                "message": "Camoufox executable was not found in the packaged browser directory.",
            }

        try:
            from camoufox.sync_api import Camoufox
        except Exception as exc:
            return {
                "ok": False,
                "error": "camoufox_import_failed",
                "message": str(exc),
            }

        headless = self._headless_value(self.config.get("headless", True))
        ff_version = self.config.get("ffVersion") or self._read_ff_version(executable)
        launch_kwargs = {
            "headless": headless,
            "executable_path": executable,
            "geoip": False,
            "i_know_what_im_doing": True,
            "env": dict(os.environ),
        }
        if self.config.get("excludeDefaultAddons", True) is not False:
            try:
                launch_kwargs["exclude_addons"] = self._default_addons_to_exclude()
            except Exception as exc:
                return {
                    "ok": False,
                    "error": "default_addon_exclusion_unavailable",
                    "message": str(exc),
                }
        if ff_version is not None:
            launch_kwargs["ff_version"] = ff_version

        try:
            self.camoufox_ctx = Camoufox(**launch_kwargs)
            self.browser = self.camoufox_ctx.__enter__()
            self.page = self.browser.new_page()
        except Exception as exc:
            self._cleanup()
            return {
                "ok": False,
                "error": "camoufox_start_failed",
                "message": str(exc),
            }

        return self.status("Camoufox browser started")

    def stop(self):
        self._cleanup()
        return {"ok": True, "message": "Camoufox browser stopped", "running": False}

    def navigate(self, command):
        url = str(command.get("url") or "").strip()
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https"):
            return {
                "ok": False,
                "error": "unsupported_scheme",
                "message": "Only http/https URLs are supported.",
            }
        started = self._ensure_started()
        if started is not None:
            return started
        timeout = self._bounded_int(command.get("timeout"), 30000, 1000, 120000)
        try:
            self.page.goto(url, wait_until="domcontentloaded", timeout=timeout)
            return {
                "ok": True,
                "message": "Page opened",
                "url": self._current_url(),
                "title": self._current_title(),
            }
        except Exception as exc:
            return {"ok": False, "error": "navigate_failed", "message": str(exc)}

    def snapshot(self):
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            text = self.page.evaluate("document.body ? document.body.innerText : ''")
            return {
                "ok": True,
                "message": text or "Page has no readable text.",
                "url": self._current_url(),
                "title": self._current_title(),
                "text": text or "",
            }
        except Exception as exc:
            return {"ok": False, "error": "snapshot_failed", "message": str(exc)}

    def evaluate(self, command):
        expression = str(command.get("expression") or "").strip()
        if not expression:
            return {
                "ok": False,
                "error": "missing_expression",
                "message": "evaluate requires an expression.",
            }
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            result = self.page.evaluate(expression)
            return {
                "ok": True,
                "message": self._message_value(result),
                "result": result,
                "url": self._current_url(),
                "title": self._current_title(),
            }
        except Exception as exc:
            return {"ok": False, "error": "evaluate_failed", "message": str(exc)}

    def screenshot(self, command):
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            full_page = bool(command.get("fullPage", False))
            data = self.page.screenshot(full_page=full_page)
            return {
                "ok": True,
                "message": "Screenshot captured",
                "screenshot": base64.b64encode(data).decode("ascii"),
                "url": self._current_url(),
                "title": self._current_title(),
            }
        except Exception as exc:
            return {"ok": False, "error": "screenshot_failed", "message": str(exc)}

    def click(self, command):
        selector = self._selector(command)
        if not selector:
            return self._missing_selector()
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            self.page.click(selector)
            return self.status("Click completed")
        except Exception as exc:
            return {"ok": False, "error": "click_failed", "message": str(exc)}

    def type_text(self, command):
        selector = self._selector(command)
        if not selector:
            return self._missing_selector()
        text = str(command.get("text") or "")
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            self.page.fill(selector, text)
            if command.get("pressEnter") is True:
                self.page.keyboard.press("Enter")
            return self.status("Input completed")
        except Exception as exc:
            return {"ok": False, "error": "type_failed", "message": str(exc)}

    def select(self, command):
        selector = self._selector(command)
        if not selector:
            return self._missing_selector()
        value = str(command.get("value") or "")
        if not value:
            return {"ok": False, "error": "missing_value", "message": "select requires value."}
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            self.page.select_option(selector, value)
            return self.status("Selection completed")
        except Exception as exc:
            return {"ok": False, "error": "select_failed", "message": str(exc)}

    def key(self, command):
        key = str(command.get("key") or "").strip()
        if not key:
            return {"ok": False, "error": "missing_key", "message": "key requires key."}
        started = self._ensure_started()
        if started is not None:
            return started
        try:
            self.page.keyboard.press(key)
            return self.status("Key press completed")
        except Exception as exc:
            return {"ok": False, "error": "key_failed", "message": str(exc)}

    def scroll(self, command):
        started = self._ensure_started()
        if started is not None:
            return started
        direction = str(command.get("direction") or "down").lower()
        amount = self._bounded_int(command.get("amount"), 600, 1, 5000)
        delta = -amount if direction == "up" else amount
        try:
            self.page.mouse.wheel(0, delta)
            return self.status("Scroll completed")
        except Exception as exc:
            return {"ok": False, "error": "scroll_failed", "message": str(exc)}

    def wait(self, command):
        started = self._ensure_started()
        if started is not None:
            return started
        timeout = self._bounded_int(command.get("timeout"), 2000, 100, 30000)
        selector = self._selector(command)
        state = str(command.get("state") or "").strip()
        try:
            if selector:
                self.page.wait_for_selector(selector, timeout=timeout)
            elif state in ("load", "domcontentloaded", "networkidle"):
                self.page.wait_for_load_state(state, timeout=timeout)
            else:
                time.sleep(timeout / 1000)
            return self.status("Wait completed")
        except Exception as exc:
            return {"ok": False, "error": "wait_failed", "message": str(exc)}

    def status(self, message="Browser status"):
        return {
            "ok": True,
            "message": message,
            "running": self.page is not None,
            "url": self._current_url(),
            "title": self._current_title(),
        }

    def dispatch(self, command):
        action = str(command.get("action") or "").strip()
        if action == "start":
            return self.start()
        if action == "stop":
            return self.stop()
        if action == "navigate":
            return self.navigate(command)
        if action == "snapshot":
            return self.snapshot()
        if action == "evaluate":
            return self.evaluate(command)
        if action == "screenshot":
            return self.screenshot(command)
        if action == "click":
            return self.click(command)
        if action == "type":
            return self.type_text(command)
        if action == "select":
            return self.select(command)
        if action == "key":
            return self.key(command)
        if action == "scroll":
            return self.scroll(command)
        if action == "wait":
            return self.wait(command)
        if action in ("status", "show"):
            return self.status()
        return {"ok": False, "error": "unknown_action", "message": f"Unknown action: {action}"}

    def _ensure_started(self):
        if self.page is not None:
            return None
        result = self.start()
        if result.get("ok") is True:
            return None
        return result

    def _cleanup(self):
        try:
            if self.camoufox_ctx is not None:
                self.camoufox_ctx.__exit__(None, None, None)
        except Exception:
            pass
        self.page = None
        self.browser = None
        self.camoufox_ctx = None

    def _find_browser_executable(self):
        data_dir = Path(str(self.config.get("browserDataDir") or ""))
        if not data_dir.exists():
            return ""
        for name in ("camoufox.exe", "firefox.exe", "camoufox-bin"):
            path = data_dir / name
            if path.exists():
                return str(path)
        for candidate in data_dir.rglob("*"):
            if candidate.name.lower() in ("camoufox.exe", "firefox.exe", "camoufox-bin"):
                return str(candidate)
        return ""

    def _read_ff_version(self, executable):
        data_dir = Path(str(self.config.get("browserDataDir") or ""))
        candidates = []
        if executable:
            executable_dir = Path(str(executable)).parent
            candidates.extend([executable_dir / "version.json", executable_dir.parent / "version.json"])
        candidates.append(data_dir / "version.json")
        if data_dir.exists():
            candidates.extend(data_dir.rglob("version.json"))
        seen = set()
        for version_file in candidates:
            if version_file in seen:
                continue
            seen.add(version_file)
            try:
                raw = json.loads(version_file.read_text(encoding="utf-8"))
                text = f"{raw.get('version', '')} {raw.get('release', '')}"
                match = re.search(r"\d+", text)
                if match:
                    return int(match.group(0))
            except Exception:
                continue
        return None

    @staticmethod
    def _default_addons_to_exclude():
        try:
            from camoufox import DefaultAddons
        except Exception:
            from camoufox.addons import DefaultAddons

        try:
            addons = list(DefaultAddons)
        except TypeError:
            addons = []
        if addons:
            return addons

        named_addons = []
        for name in ("UBO", "BPC"):
            addon = getattr(DefaultAddons, name, None)
            if addon is not None:
                named_addons.append(addon)
        if named_addons:
            return named_addons
        raise RuntimeError("Camoufox DefaultAddons enum is empty or unsupported.")

    def _current_url(self):
        if self.page is None:
            return None
        try:
            return self.page.url
        except Exception:
            return None

    def _current_title(self):
        if self.page is None:
            return None
        try:
            title = self.page.title()
            return title or None
        except Exception:
            return None

    @staticmethod
    def _headless_value(value):
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in ("false", "0", "no", "headed"):
                return False
            return True
        return True

    @staticmethod
    def _bounded_int(value, fallback, minimum, maximum):
        try:
            parsed = int(value)
        except Exception:
            parsed = fallback
        return max(minimum, min(maximum, parsed))

    @staticmethod
    def _message_value(value):
        if value is None:
            return ""
        if isinstance(value, str):
            return value
        return json.dumps(value, ensure_ascii=False)

    @staticmethod
    def _selector(command):
        selector = command.get("selector")
        if selector is None:
            selector = command.get("ref")
        if selector is None:
            return ""
        return str(selector).strip()

    @staticmethod
    def _missing_selector():
        return {
            "ok": False,
            "error": "missing_selector",
            "message": "This browser action requires selector or ref.",
        }


def write_response(command_id, result):
    payload = {"id": command_id, **result}
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def main():
    if len(sys.argv) < 2:
        print(json.dumps({
            "id": None,
            "ok": False,
            "error": "missing_config",
            "message": "Config path argument is required.",
        }), flush=True)
        return 2

    bridge = BrowserBridge(sys.argv[1])
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        command_id = None
        try:
            command = json.loads(line)
            command_id = command.get("id")
            result = bridge.dispatch(command)
            write_response(command_id, result)
        except Exception as exc:
            print(traceback.format_exc(), file=sys.stderr, flush=True)
            write_response(command_id, {
                "ok": False,
                "error": "bridge_exception",
                "message": str(exc),
            })
    bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
