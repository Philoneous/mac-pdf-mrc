# SPDX-License-Identifier: AGPL-3.0-or-later
"""Ersatz für einen Paperless-ngx-Server (3.3.0, API-Version 10) mit den Endpunkten, die die App nutzt.

Verhalten nach dem Quellcode von paperless-ngx v3.3.0:
- POST /api/documents/post_document/: Formularfeld "document", Content-Length verlangt; Antwort = Task-ID als
  JSON-String (PostDocumentView: ``return Response(async_task.id)``).
- GET /api/tasks/?task_id=…: seitenweise ({"count", "results"}), status klein geschrieben, result_data
  {"document_id": …}; bei Duplikaten {"duplicate_of": …} mit status "failure" (signals/handlers.py).
- GET /api/documents/: zum Prüfen von Verbindung und Token.
Falsches Token: 401. Die erste Task-Abfrage meldet "started", erst die zweite das Ergebnis.
"""

import hashlib
import json
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TOKEN = "geheim-123"


def parse_multipart(content_type: str, body: bytes) -> dict[str, tuple[str | None, bytes]]:
    """Minimaler multipart/form-data-Parser (Kopfzeilen als UTF-8 wie Djangos MultiPartParser)."""
    boundary = re.search(r'boundary="?([^";]+)"?', content_type).group(1).encode()
    fields = {}
    for part in body.split(b"--" + boundary)[1:]:
        if part.startswith(b"--"):
            break
        head, _, data = part.lstrip(b"\r\n").partition(b"\r\n\r\n")
        headers = head.decode("utf-8")
        name = re.search(r'name="([^"]*)"', headers).group(1)
        filename = re.search(r'filename="([^"]*)"', headers)
        fields[name] = (filename.group(1) if filename else None, data.removesuffix(b"\r\n"))
    return fields


class Paperless:
    def __init__(self) -> None:
        self.uploads: list[tuple[str | None, bytes]] = []
        self.tasks: dict[str, dict] = {}
        self.documents: dict[str, int] = {}  # Prüfsumme -> Dokument-ID
        self.next_id = 42

    def start(self) -> str:
        state = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:
                pass

            def reply(self, code: int, obj) -> None:
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def authorized(self) -> bool:
                if self.headers.get("Authorization") != f"Token {TOKEN}":
                    self.reply(401, {"detail": "Ungültiges Token."})
                    return False
                return True

            def do_GET(self) -> None:
                if not self.authorized():
                    return
                url = urlparse(self.path)
                if url.path == "/api/documents/":
                    return self.reply(200, {"count": 0, "next": None, "previous": None, "results": []})
                if url.path == "/api/tasks/":
                    task_id = parse_qs(url.query).get("task_id", [""])[0]
                    results = []
                    if task := state.tasks.get(task_id):
                        task["polls"] += 1
                        done = task["polls"] > 1
                        result = task["result"] if done else None
                        results = [{"id": 1, "task_id": task_id, "task_type": "consume_file",
                                    "status": task["status"] if done else "started", "result_data": result,
                                    "related_document_ids": list((result or {}).values())}]
                    return self.reply(200, {"count": len(results), "next": None, "previous": None,
                                            "results": results})
                self.reply(404, {"detail": "Nicht gefunden."})

            def do_POST(self) -> None:
                if not self.authorized():
                    return
                if urlparse(self.path).path != "/api/documents/post_document/":
                    return self.reply(404, {"detail": "Nicht gefunden."})
                if "Content-Length" not in self.headers:
                    return self.reply(411, {"detail": "Content-Length fehlt."})
                body = self.rfile.read(int(self.headers["Content-Length"]))
                fields = parse_multipart(self.headers["Content-Type"], body)
                if "document" not in fields:
                    return self.reply(400, {"document": ["Dieses Feld ist erforderlich."]})
                filename, data = fields["document"]
                state.uploads.append((filename, data))
                checksum = hashlib.md5(data).hexdigest()
                task_id = str(uuid.uuid4())
                if checksum in state.documents:
                    state.tasks[task_id] = {"polls": 0, "status": "failure",
                                            "result": {"duplicate_of": state.documents[checksum]}}
                else:
                    state.documents[checksum] = state.next_id
                    state.tasks[task_id] = {"polls": 0, "status": "success", "result": {"document_id": state.next_id}}
                    state.next_id += 1
                self.reply(200, task_id)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self.server.server_port}"
