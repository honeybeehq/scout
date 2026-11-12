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
for case, mode in [("success", "success"), ("failure", "failure"), ("cancel", "wait"), ("timeout", "wait")]:
    folder = output / case
    folder.mkdir(exist_ok=True)
    socket_path = str(pathlib.Path(tempfile.gettempdir()) / ("scout-opt-" + os.urandom(5).hex() + ".sock"))
    server = subprocess.Popen([sys.executable, str(root / "script/optimise/mock-hive.py"), socket_path, str(fixture), str(folder / "spawn.json"), mode])
    try:
        for _ in range(100):
            if pathlib.Path(socket_path).exists():
                break
            time.sleep(0.01)
        environment = dict(os.environ, HIVE_V2_SOCKET_PATH=socket_path)
        arguments = [str(app), "--optimise-replay=" + str(folder), "--optimise-fixture=" + str(fixture), "--optimise-via-agent=yes"]
        if case != "success":
            arguments.append("--optimise-expect=" + case)
        result = subprocess.run(arguments, env=environment, capture_output=True, text=True, timeout=200)
        (folder / "process.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        server.wait(timeout=10)
        assert server.returncode == 0
        report = json.loads((folder / "report.json").read_text())
        if case in ["cancel", "timeout"]:
            stop = json.loads((folder / "spawn.json.stop.json").read_text())
            assert stop["params"]["beeId"] == "fixture-agent"
        if case == "timeout":
            assert 179 <= report["elapsed"] <= 190
        print(case + ": PASS", flush=True)
    finally:
        if server.poll() is None:
            server.terminate()
            server.wait(timeout=5)
        pathlib.Path(socket_path).unlink(missing_ok=True)
