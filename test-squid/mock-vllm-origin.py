#!/usr/bin/env python3
# =============================================================================
# mock-vllm-origin.py —— vLLM 通信模拟源站（仅标准库）
#
# 形态对齐 vllm-ascend 仓库的真实通信（见 CASES.md「vllm 组」取证记录）：
#   1. 模型下载：vllm-ascend CI/运行时首选 ModelScope（modelscope download /
#      snapshot_download，URL /api/v1/models/{org}/{repo}/repo?FilePath=…），
#      HF 回退通道为 hf-mirror 形态（/{org}/{repo}/resolve/{rev}/{file}）。
#      两种通道本 mock 都支持；带 Cache-Control / Accept-Ranges / 206 Range
#      （huggingface_hub/modelscope 客户端的断点续传形态）。
#   2. OpenAI 兼容 API：GET /health（conftest 探活端点）、/v1/models、
#      POST /v1/chat/completions（stream → SSE 逐 token + [DONE]，chunk 含
#      stop_reason 字段；请求/响应携带 X-Request-Id）。
#   注：HCCL/RDMA/KV-cache 传输为 NPU 私网 P2P，不经 HTTP 代理，不在模拟范围。
#
# 模型文件内容确定性生成（按 tag+块序号哈希扩展），同 tag 重启 sha256 不变；
# 启动时写 manifest.json（路径→sha256），套件据此做完整性校验。
# =============================================================================
import argparse
import hashlib
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 模型仓库清单：文件名 → 大小（vLLM 拉模型的典型构成）
MODEL_FILES = {
    "config.json": 1024,                      # 1KB
    "tokenizer.json": 64 * 1024,              # 64KB
    "model-00001-of-00002.safetensors": 16 * 1024 * 1024,   # 16MB
    "model-00002-of-00002.safetensors": 8 * 1024 * 1024,    # 8MB
}

CHUNK = 65536  # 生成块大小


def gen_file(path: str, size: int, tag: str) -> str:
    """确定性生成 size 字节的文件，返回 sha256（内容随 tag+块序号变化但可复现）"""
    h = hashlib.sha256()
    i, written = 0, 0
    with open(path, "wb") as f:
        while written < size:
            n = min(CHUNK, size - written)
            block = hashlib.sha256(f"{tag}:{i}".encode()).digest()
            data = (block * (n // 32 + 1))[:n]
            f.write(data)
            h.update(data)
            written += n
            i += 1
    return h.hexdigest()


def build_repo(root: str, tag: str) -> None:
    """生成模型仓库 + manifest.json（路径 → sha256）"""
    os.makedirs(root, exist_ok=True)
    manifest = {}
    for name, size in MODEL_FILES.items():
        manifest[name] = gen_file(os.path.join(root, name), size, f"{tag}/{name}")
    with open(os.path.join(root, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)


class Handler(BaseHTTPRequestHandler):
    serve_dir = "/tmp/mock-vllm-repo"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 静默默认访问日志（套件日志已经很吵）
        pass

    # ---------- 静态模型仓库（ModelScope / HF 双通道）----------
    def do_GET(self):
        raw = self.path.split("?")[0]
        if self.path.startswith("/health"):
            # vllm-ascend e2e conftest 的探活端点形态
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if raw == "/v1/models":
            import time
            return self._json({"object": "list", "data": [
                {"id": "mock-vllm-model", "object": "model",
                 "created": int(time.time()), "owned_by": "vllm"}]})
        # ModelScope 通道：/api/v1/models/{org}/{repo}/repo?Revision=…&FilePath={file}
        if raw.endswith("/repo"):
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            name = (qs.get("FilePath") or [""])[0].split("/")[-1]
        else:
            # HF/hf-mirror 通道：/{org}/{repo}/resolve/{rev}/{file}
            name = raw.split("/")[-1]
        if not name:
            return self._json({"error": f"no such object: {raw}"}, 404)
        full = os.path.join(self.serve_dir, name)
        if name not in MODEL_FILES or not os.path.isfile(full):
            return self._json({"error": f"no such object: {name}"}, 404)
        size = os.path.getsize(full)
        base_headers = [
            ("Cache-Control", "max-age=3600"),       # 允许 squid 缓存（MISS→HIT 可观测）
            ("Accept-Ranges", "bytes"),
            ("Content-Type", "application/json" if name.endswith(".json") else "application/octet-stream"),
        ]
        rng = self.headers.get("Range")
        m = re.match(r"bytes=(\d*)-(\d*)$", rng or "")
        if m and (m.group(1) or m.group(2)):
            start = int(m.group(1)) if m.group(1) else max(0, size - int(m.group(2)))
            end = int(m.group(2)) if m.group(2) else size - 1
            end = min(end, size - 1)
            self.send_response(206)
            for k, v in base_headers:
                self.send_header(k, v)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            with open(full, "rb") as f:
                f.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = f.read(min(CHUNK, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        else:
            self.send_response(200)
            for k, v in base_headers:
                self.send_header(k, v)
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(full, "rb") as f:
                while True:
                    chunk = f.read(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

    # ---------- OpenAI 兼容 API（chat/completions）----------
    def do_POST(self):
        if self.path.split("?")[0] != "/v1/chat/completions":
            return self._json({"error": "not found"}, 404)
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (json.JSONDecodeError, ValueError):
            return self._json({"error": "bad json"}, 400)
        n = int(body.get("max_tokens", 8))
        cid = "chatcmpl-mock-vllm"
        if body.get("stream"):
            # SSE 形态：逐 token 分块（delta.content，finish_reason/stop_reason 均为
            # null 的中间块），结尾 [DONE]；与 vllm-ascend 仓库内 OpenAI server
            # 的真实 chunk 结构对齐（tests/ut/proxy/test_load_balance_proxy_server.py）
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")   # SSE 无 Content-Length，须显式关连接
            self.send_header("X-Request-Id", self.headers.get("X-Request-Id", "mock-req-1"))
            self.end_headers()
            self.close_connection = True
            for i in range(n):
                last = i == n - 1
                chunk = {"id": cid, "object": "chat.completion.chunk",
                         "choices": [{"index": 0, "delta": {"content": f"tok{i}"},
                                      "finish_reason": "stop" if last else None,
                                      "stop_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        else:
            self._json({"id": cid, "object": "chat.completion",
                        "choices": [{"index": 0, "message": {"content": "t" * n},
                                     "finish_reason": "stop"}]},
                       extra_headers={"X-Request-Id": self.headers.get("X-Request-Id", "mock-req-1")})

    def _json(self, obj, code=200, extra_headers=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--dir", required=True, help="模型仓库目录（自动生成）")
    ap.add_argument("--tag", default="run", help="文件内容种子（跨 run 可复现）")
    args = ap.parse_args()
    build_repo(args.dir, args.tag)
    Handler.serve_dir = args.dir
    print(f"mock origin serving {args.dir} on :{args.port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
