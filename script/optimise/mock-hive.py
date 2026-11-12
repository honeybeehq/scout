import json
import os
import pathlib
import socket
import sys

socket_path, fixture, capture = sys.argv[1:4]
mode = sys.argv[4] if len(sys.argv) > 4 else "success"
server = socket.socket(socket.AF_UNIX)
server.bind(socket_path)
server.listen(2)
try:
    for _ in range(2 if mode == "wait" else 1):
        connection, _ = server.accept()
        with connection, connection.makefile("rwb") as stream:
            stream.write(b'{"protocol":"v2/2"}\n')
            stream.flush()
            json.loads(stream.readline())
            request = json.loads(stream.readline())
            if request["verb"] == "stop":
                pathlib.Path(capture + ".stop.json").write_text(json.dumps(request, indent=2))
                stream.write(b'{"id":1,"ok":true,"result":{}}\n')
                stream.flush()
                continue
            pathlib.Path(capture).write_text(json.dumps(request, indent=2))
            assert request["verb"] == "spawn"
            assert request["params"]["agent"] == "claude"
            prompt = request["params"]["prompt"]
            assert "Full transcript:" in prompt and "Full ledger:" in prompt
            assert "[Attached video:" not in prompt
            if mode == "success":
                destination = pathlib.Path(request["params"]["cwd"]) / "optimise.v1.json"
                temporary = destination.with_suffix(".tmp")
                temporary.write_bytes(pathlib.Path(fixture).read_bytes())
                os.replace(temporary, destination)
            response = {"id": 1, "ok": False, "error": {"message": "Fixture spawn failure"}} if mode == "failure" else {"id": 1, "ok": True, "result": {"beeId": "fixture-agent"}}
            stream.write(json.dumps(response).encode() + b"\n")
            stream.flush()
finally:
    server.close()
    os.unlink(socket_path)
