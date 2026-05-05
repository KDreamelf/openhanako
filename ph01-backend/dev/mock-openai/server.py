from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/healthz":
            self._json({"ok": True, "service": "mock-openai"})
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_error(400)
            return

        model = payload.get("model", "mock-gpt")
        messages = payload.get("messages") or []
        user_text = ""
        if messages:
            content = messages[-1].get("content", "")
            user_text = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)

        if payload.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            chunks = [
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "model": model,
                    "choices": [
                        {"index": 0, "delta": {"content": "mock stream: "}, "finish_reason": None}
                    ],
                },
                {
                    "id": "chatcmpl-mock",
                    "object": "chat.completion.chunk",
                    "model": model,
                    "choices": [
                        {"index": 0, "delta": {"content": user_text}, "finish_reason": "stop"}
                    ],
                },
            ]
            for item in chunks:
                data = json.dumps(item, ensure_ascii=False)
                self.wfile.write(f"data: {data}\n\n".encode("utf-8"))
                self.wfile.flush()
                time.sleep(0.02)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return

        self._json(
            {
                "id": "chatcmpl-mock",
                "object": "chat.completion",
                "model": model,
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": f"mock reply: {user_text}",
                        },
                        "finish_reason": "stop",
                    }
                ],
            }
        )

    def _json(self, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
