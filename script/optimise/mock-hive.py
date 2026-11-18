import json
import os
import pathlib
import socket
import sys
import threading
import time

socket_path, fixture, capture = sys.argv[1:4]
mode = sys.argv[4] if len(sys.argv) > 4 else "success"
server = socket.socket(socket.AF_UNIX)
server.bind(socket_path)
server.listen(8)
server.settimeout(1)
state = {"runtime": "running", "generation": 1, "delivered": True, "pending": False, "events": []}
log = pathlib.Path(capture + ".transcript.jsonl")
log.write_text("")
started = time.monotonic()

def save():
    pathlib.Path(capture + ".state.json").write_text(json.dumps(state, indent=2))

def wake():
    time.sleep(0.002)
    state.update(runtime="running", generation=2, delivered=True, pending=False)
    state["events"].append("send_wake:gen2")
    save()

try:
    while time.monotonic() - started < 210:
        try:
            connection, _ = server.accept()
        except socket.timeout:
            continue
        with connection, connection.makefile("rwb") as stream:
            stream.write(b'{"protocol":"v2/2"}\n')
            stream.flush()
            json.loads(stream.readline())
            request = json.loads(stream.readline())
            verb = request["verb"]
            response = {"id": 1, "ok": True, "result": {}}
            if verb == "spawn":
                pathlib.Path(capture).write_text(json.dumps(request, indent=2))
                workspace = pathlib.Path(request["params"]["cwd"])
                state["inputs"] = [str(p.relative_to(workspace)) for p in workspace.rglob("*") if p.is_file()]
                state["events"].append("spawn:gen1")
                if mode == "failure":
                    response = {"id": 1, "ok": False, "error": {"message": "Fixture spawn failure"}}
                else:
                    response["result"] = {"beeId": "fixture-agent"}
                    if mode in ["race", "late-race"]:
                        state.update(delivered=False, pending=True)
                    elif mode in ["success", "stop-failure", "invalid", "benign", "prose", "fenced", "stopped-mail", "mail-flicker", "cleanup-timeout"]:
                        text = pathlib.Path(fixture).read_text() if mode != "invalid" else '{"v":2,"proposals":[]}'
                        if mode == "prose":
                            text = "Permission to create the file was declined; I cannot write the result."
                        if mode == "fenced":
                            text = "```json\n" + text + "\n```"
                        log.write_text(json.dumps({"type": "user", "message": {"content": "PRIVATE RAW TRANSCRIPT MUST NOT BE COPIED"}}) + "\n" + json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}) + "\n" + json.dumps({"type": "result", "subtype": "success", "result": text}) + "\n")
                        state["runtime"] = "idle"
                        if mode == "stopped-mail":
                            state.update(runtime="stopped", delivered=False)
                    elif mode in ["boot-failure", "boot-crash"]:
                        state["runtime"] = "stopped"
            elif verb == "view":
                flags = ["spawn_failed"] if mode == "boot-failure" else (["future_benign_flag"] if mode == "benign" else [])
                response["result"] = {"bee": {"id": "fixture-agent", "sessionLogPath": str(log), "env": {"SECRET": "MUST_NOT_BE_STORED"}}, "view": {"flags": flags, "working": state["runtime"] == "running"}, "runtime": {"generation": state["generation"], "state": state["runtime"], "exitCause": "crashed" if mode in ["boot-failure", "boot-crash"] else None}}
            elif verb == "commands":
                response["result"] = {"commands": [{"verb": "spawn", "status": "failed", "failureCause": "spawn_failed"}]} if mode == "boot-failure" else {"commands": [{"verb": "send_wake", "status": "queued"}] if state["pending"] else []}
            elif verb == "audit.tail":
                response["result"] = {"rows": [{"kind": "command.requeued", "payload": {"detail": "EPERM fixture cwd"}}]}
            elif verb == "mailbox":
                if mode == "mail-flicker":
                    state["mailboxPolls"] = state.get("mailboxPolls", 0) + 1
                    state["delivered"] = state["mailboxPolls"] % 2 == 1
                response["result"] = {"messages": [{"id": 1, "deliveredAt": 123 if state["delivered"] else None}]}
            elif verb == "stop":
                state["events"].append("stop:gen" + str(state["generation"]))
                pathlib.Path(capture + ".stop.json").write_text(json.dumps(request, indent=2))
                if mode == "stop-failure":
                    response = {"id": 1, "ok": False, "error": {"message": "Fixture stop RPC failed"}}
                elif mode == "cleanup-timeout":
                    pass
                else:
                    if state["runtime"] == "stopped":
                        response["result"] = {"status": "moot", "reason": "already_stopped"}
                    state["runtime"] = "stopped"
                    if mode in ["race", "late-race"] and state["generation"] == 1:
                        threading.Thread(target=wake, daemon=True).start()
            else:
                response = {"id": 1, "ok": False, "error": {"message": "Unexpected verb " + verb}}
            if verb == "spawn" and mode == "late-race":
                time.sleep(0.15)
            save()
            stream.write(json.dumps(response).encode() + b"\n")
            stream.flush()
finally:
    save()
    server.close()
    pathlib.Path(socket_path).unlink(missing_ok=True)
