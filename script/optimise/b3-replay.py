import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import uuid

app = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
root = pathlib.Path(__file__).resolve().parents[2]
output.mkdir(parents=True, exist_ok=True)
fixture = root / "Fixtures/optimise/playtest.optimise.v1.json"
cases = ["success", "benign", "race", "late-race", "boot-failure", "boot-crash", "stop-failure", "invalid", "prose", "fenced", "stopped-mail", "mail-flicker", "cleanup-timeout"]
selected = set(sys.argv[3:])
for mode in cases:
    if selected and mode not in selected:
        continue
    folder = output / mode
    folder.mkdir(exist_ok=True)
    socket_path = str(pathlib.Path(tempfile.gettempdir()) / ("scout-b3-" + os.urandom(5).hex() + ".sock"))
    capture = folder / "spawn.json"
    data_root = output / "data"
    workspace_root = data_root / "OptimiseRuns"
    workspace_root.mkdir(parents=True, exist_ok=True)
    stale = workspace_root / str(uuid.uuid4())
    fresh = workspace_root / str(uuid.uuid4())
    stale.mkdir()
    fresh.mkdir()
    os.utime(stale, (time.time() - 172800, time.time() - 172800))
    server = subprocess.Popen([sys.executable, str(root / "script/optimise/mock-hive.py"), socket_path, str(fixture), str(capture), mode])
    try:
        for _ in range(100):
            if pathlib.Path(socket_path).exists():
                break
            time.sleep(0.01)
        arguments = [str(app), "--optimise-replay=" + str(folder), "--optimise-fixture=" + str(fixture), "--optimise-via-agent=yes"]
        if mode in ["race", "late-race"]:
            arguments.append("--optimise-expect=cancel")
        if mode in ["boot-failure", "boot-crash", "invalid", "prose"]:
            arguments.append("--optimise-expect=failure")
        started = time.monotonic()
        result = subprocess.run(arguments, env=dict(os.environ, HIVE_V2_SOCKET_PATH=socket_path, SCOUT_DATA_ROOT=str(data_root)), capture_output=True, text=True, timeout=30)
        (folder / "process.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        report = json.loads((folder / "report.json").read_text())
        state = json.loads(pathlib.Path(str(capture) + ".state.json").read_text())
        request = json.loads(capture.read_text())
        workspace = pathlib.Path(request["params"]["cwd"])
        assert workspace.parent == workspace_root
        assert not stale.exists() and fresh.exists()
        fresh.rmdir()
        assert "--dangerously-skip-permissions" not in json.dumps(request)
        assert "args" not in request["params"]
        assert "optimise-ledger.json" in state["inputs"] and "review.json" in state["inputs"]
        assert not any(p.endswith((".mp4", ".aiff", ".wav", ".m4a")) for p in state["inputs"])
        assert workspace.exists() == (mode in ["stop-failure", "cleanup-timeout"])
        if mode in ["success", "stop-failure", "benign", "fenced", "stopped-mail", "mail-flicker", "cleanup-timeout"]:
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
        if mode in ["invalid", "prose"]:
            assert report["reviewUntouched"]
            assert "Claude replied without a valid result" in report["error"]
        if mode == "prose":
            assert "Permission to create the file was declined" in report["error"]
        stops = [event for event in state["events"] if event.startswith("stop:")]
        assert len(stops) <= (2 if mode in ["race", "late-race"] else 1)
        if mode in ["stop-failure", "cleanup-timeout"]:
            assert report["cleanupError"] and "cleanup failed" in result.stderr
        else:
            assert not report["cleanupError"]
        if mode == "cleanup-timeout":
            assert "undelivered=" in report["cleanupError"]
            assert result.stderr.count("stop confirmation timed out") == 1
        (folder / "stop-check.json").write_text(json.dumps({"stopCount": len(stops), "finalState": state["runtime"], "generation": state["generation"], "cleanupError": report["cleanupError"]}, indent=2))
        (folder / "workspace-check.json").write_text(json.dumps({"removed": not workspace.exists(), "retainedForUnconfirmedStop": mode in ["stop-failure", "cleanup-timeout"], "oldWorkspaceSwept": not stale.exists(), "freshWorkspaceKept": True}, indent=2))
        print(mode + ": PASS", flush=True)
    finally:
        server.terminate()
        server.wait(timeout=5)
        pathlib.Path(socket_path).unlink(missing_ok=True)
