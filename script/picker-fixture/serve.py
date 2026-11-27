import json
import os
import secrets
import socket
import sys
import threading
import time
from datetime import datetime, timezone

if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and sys.argv[3] != "--no-context"):
    sys.exit("usage: serve.py <fixture.json> <run dir> [--no-context]")
fixture = json.load(open(sys.argv[1]))
context = len(sys.argv) == 3
run = os.path.abspath(sys.argv[2])
os.makedirs(run, exist_ok=True)
apiary_path = os.path.join(run, "apiary.sock")
hive_path = os.path.join(run, "hived.sock")
token = secrets.token_hex(16)
instance = "fixture-" + secrets.token_hex(4)
log = open(os.path.join(run, "serve.log"), "a", buffering=1)
now = time.time() * 1000


def stamp(value):
    if isinstance(value, str) and value.startswith("now-") and value[-1] in "mhd":
        at = now - float(value[4:-1]) * {"m": 60_000, "h": 3_600_000, "d": 86_400_000}[value[-1]]
        return datetime.fromtimestamp(at / 1000, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return value


def millis(value):
    return round(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)


def row(target, include=True):
    shaped = {key: stamp(value) for key, value in target.items()}
    if "bio" in shaped:
        shaped["bio"] = shaped["bio"][:200]
    if not context or not include:
        shaped.pop("bio", None)
        shaped.pop("lastActiveAt", None)
    return shaped


targets = [row(target) for target in fixture.get("targets", [])]
hive_views = fixture.get("hive") or [
    {
        "bee": {"id": target["sessionId"], "lifecycle": "active", "name": target["title"], "title": target.get("sessionTitle"), "lastOutputAt": millis(stamp(target["lastActiveAt"])), "tags": []},
        "view": {},
        "runtime": {"state": "running"},
    }
    for target in fixture.get("targets", [])
    if target.get("sessionId") and target.get("lastActiveAt")
]
capabilities = ["focusedChat", "listTargets", "listTargets.look", "deliver"] + (["listTargets.context"] if context else [])


def lines(conn):
    buffer = b""
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            return
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if line.strip():
                yield json.loads(line)


def send(conn, value):
    conn.sendall(json.dumps(value).encode() + b"\n")


def apiary(conn):
    for request in lines(conn):
        verb = request.get("verb")
        log.write(f"apiary {verb}\n")
        if verb == "hello":
            if request.get("params", {}).get("token") != token:
                send(conn, {"id": request["id"], "ok": False, "error": {"code": "unauthorized", "message": "bad token"}})
                continue
            result = {"apiary": {"instanceId": instance}, "capabilities": capabilities, "windows": []}
        elif verb == "focusedChat":
            result = {"target": fixture["focused"]} if fixture.get("focused") else {}
        elif verb == "listTargets":
            wants = request.get("params", {}).get("context", True) is not False
            result = {"targets": targets if wants else [row(target, False) for target in fixture.get("targets", [])]}
        elif verb == "deliver":
            params = request.get("params", {})
            target = params.get("target", {})
            title = next((row["title"] for row in targets if row["kind"] == target.get("kind") and row["id"] == target.get("id")), "")
            log.write(f"apiary deliver {target.get('kind')}:{target.get('id')} {params.get('mode')} {title}\n")
            result = {"target": {"title": title}} if title else {}
        else:
            send(conn, {"id": request["id"], "ok": False, "error": {"code": "unknownVerb", "message": verb}})
            continue
        send(conn, {"id": request["id"], "ok": True, "result": result})


def hive(conn):
    send(conn, {"protocol": "v2/2"})
    for request in lines(conn):
        if "verb" not in request:
            continue
        log.write(f"hive {request['verb']}\n")
        if request["verb"] == "list":
            send(conn, {"id": request["id"], "ok": True, "result": {"views": hive_views}})
        else:
            send(conn, {"id": request["id"], "ok": False, "error": {"message": "fixture hive only lists"}})


def listen(path, handler):
    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(8)

    def accept():
        while True:
            conn, _ = server.accept()
            threading.Thread(target=lambda: (handler(conn), conn.close()), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()


listen(apiary_path, apiary)
listen(hive_path, hive)
with open(os.path.join(run, "scout-bridge.json"), "w") as out:
    json.dump({"protocol": "apiary-scout/1", "socketPath": apiary_path, "token": token, "pid": os.getpid(), "instanceId": instance}, out)
print(json.dumps({"bridge": os.path.join(run, "scout-bridge.json"), "hive": hive_path}), flush=True)
threading.Event().wait()
