#!/usr/bin/env python3
"""Exercise the built Ollama example against an isolated OpenAI HTTP fixture."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 scripts/smoke-example.py /absolute/path/to/ollama-chat")
    executable = Path(sys.argv[1]).resolve()
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append((self.path, dict(self.headers), body))
            if self.path != "/proxy/v1/chat/completions":
                self.send_error(404)
                return
            response = {
                "id": "fixture-completion",
                "object": "chat.completion",
                "created": 0,
                "model": "fixture-model",
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": "fixture reply 🌙"},
                    "finish_reason": "stop",
                }],
                "usage": {"prompt_tokens": 3, "completion_tokens": 5, "total_tokens": 8},
            }
            self.send_response(200)
            if not body["stream"]:
                data = json.dumps(response).encode("utf-8")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for text in ["fixture ", "reply 🌙"]:
                chunk = {
                    "id": response["id"], "object": "chat.completion.chunk", "created": 0,
                    "model": response["model"],
                    "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": None}],
                }
                self.event(chunk)
            self.event({
                "id": response["id"], "object": "chat.completion.chunk", "created": 0,
                "model": response["model"],
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                "usage": response["usage"],
            })
            self.event("[DONE]")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

        def event(self, event):
            payload = event if isinstance(event, str) else json.dumps(event, ensure_ascii=False)
            data = ("data: " + payload + "\n\n").encode("utf-8")
            self.wfile.write(("%X\r\n" % len(data)).encode("ascii") + data + b"\r\n")
            self.wfile.flush()

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = dict(os.environ)
        environment["OLLAMA_BASE_URL"] = "http://127.0.0.1:%s/proxy/v1" % server.server_port
        environment["OPENAI_API_KEY"] = "fixture-cloud-key-must-not-be-sent"
        environment["OPENAI_ORG_ID"] = "fixture-cloud-org-must-not-be-sent"
        environment["OPENAI_PROJECT_ID"] = "fixture-cloud-project-must-not-be-sent"
        try:
            for arguments in [[], ["--stream"]]:
                result = subprocess.run(
                    [str(executable), "fixture-model", "fixture prompt"] + arguments,
                    env=environment, capture_output=True, text=True, timeout=10,
                )
                assert result.returncode == 0, result.stderr
                assert "fixture reply 🌙" in result.stdout, result.stdout
                if arguments:
                    assert "Total tokens: 8" in result.stdout, result.stdout
            assert len(requests) == 2, requests
            for index, (path, headers, body) in enumerate(requests):
                assert path == "/proxy/v1/chat/completions", path
                normalized = {name.lower(): value for name, value in headers.items()}
                assert "authorization" not in normalized, "Ollama configuration inherited cloud authentication"
                assert "openai-organization" not in normalized, "Ollama configuration inherited cloud organization"
                assert "openai-project" not in normalized, "Ollama configuration inherited cloud project"
                assert body["model"] == "fixture-model", body
                assert body["messages"][-1]["content"] == "fixture prompt", body
                assert body["stream"] is bool(index), body
        finally:
            server.shutdown()
            thread.join(timeout=2)
    print("Example smoke passed: JSON and streaming, URL prefix, prompt, usage, and Ollama authentication")


if __name__ == "__main__":
    main()
