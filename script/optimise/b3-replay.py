import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
root = pathlib.Path(__file__).resolve().parents[2]
output.mkdir(parents=True, exist_ok=True)
fixture = root / "Fixtures/optimise/playtest.optimise.v1.json"
cases = ["success", "race", "late-race", "boot-failure", "boot-crash", "stop-failure", "invalid"]
for mode in cases:
    folder = output / mode
    folder.mkdir(exist_ok=True)
    socket_path = str(pathlib.Path(tempfile.gettempdir()) / ("scout-b3-" + os.urandom(5).hex() + ".sock"))
    capture = folder / "spawn.json"
    server = subprocess.Popen([sys.executable, str(root / "script/optimise/mock-hive.py"), socket_path, str(fixture), str(capture), mode])
    try:
        for _ in range(100):
            if pathlib.Path(socket_path).exists():
                break
            time.sleep(0.01)
        arguments = [str(app), "--optimise-replay=" + str(folder), "--optimise-fixture=" + str(fixture), "--optimise-via-agent=yes"]
        if mode in ["race", "late-race"]:
            arguments.append("--optimise-expect=cancel")
        if mode in ["boot-failure", "boot-crash", "invalid"]:
            arguments.append("--optimise-expect=failure")
        started = time.monotonic()
        result = subprocess.run(arguments, env=dict(os.environ, HIVE_V2_SOCKET_PATH=socket_path), capture_output=True, text=True, timeout=30)
        (folder / "process.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        report = json.loads((folder / "report.json").read_text())
        state = json.loads(pathlib.Path(str(capture) + ".state.json").read_text())
        request = json.loads(capture.read_text())
        workspace = pathlib.Path(request["params"]["cwd"])
        assert "Library/Application Support/Scout-Optimise-Runs/" in str(workspace)
        assert "--dangerously-skip-permissions" not in json.dumps(request)
        assert "args" not in request["params"]
        assert (workspace / "optimise-ledger.json").exists()
        assert (workspace / "review.json").exists()
        assert not list(workspace.rglob("*.mp4")) and not list(workspace.rglob("*.aiff"))
        if mode in ["success", "stop-failure"]:
            session = pathlib.Path(report["sessionCopy"])
            document = json.loads((session / "optimise.v1.json").read_text())
            assert document["v"] == 1
            assert not (workspace / "optimise.v1.json").exists()
            assert "MUST_NOT_BE" not in json.dumps(document)
            assert "PRIVATE RAW TRANSCRIPT" not in json.dumps(document)
        if mode in ["race", "late-race"]:
            assert state["events"][:3] == ["spawn:gen1", "stop:gen1", "send_wake:gen2"]
            assert "stop:gen2" in state["events"] and state["runtime"] == "stopped"
            assert report["reviewUntouched"]
        if mode in ["boot-failure", "boot-crash"]:
            assert "EPERM" in report["error"]
            assert time.monotonic() - started < 5
        if mode == "invalid":
            assert report["reviewUntouched"]
        print(mode + ": PASS", flush=True)
    finally:
        server.terminate()
        server.wait(timeout=5)
        pathlib.Path(socket_path).unlink(missing_ok=True)
