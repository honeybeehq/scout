import json
import os
import secrets
import socket
import sys
import threading

if len(sys.argv) != 3:
    sys.exit("usage: serve.py <fixture.json> <run dir>")
fixture = json.load(open(sys.argv[1]))
run = os.path.abspath(sys.argv[2])
os.makedirs(run, exist_ok=True)
apiary_path = os.path.join(run, "apiary.sock")
hive_path = os.path.join(run, "hived.sock")
token = secrets.token_hex(16)
instance = "fixture-" + secrets.token_hex(4)
log = open(os.path.join(run, "serve.log"), "a", buffering=1)


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
            result = {"apiary": {"instanceId": instance}, "capabilities": ["focusedChat", "listTargets", "listTargets.look", "deliver"], "windows": []}
        elif verb == "focusedChat":
            result = {"target": fixture["focused"]} if fixture.get("focused") else {}
        elif verb == "listTargets":
            result = {"targets": fixture.get("targets", [])}
        elif verb == "deliver":
            result = {}
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
            send(conn, {"id": request["id"], "ok": True, "result": {"views": fixture.get("hive", [])}})
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
