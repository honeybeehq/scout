# Contributor checks

Use your own development signing team as described in the [source build instructions](../README.md#build-from-source).

## Isolate recording data

Build a test copy with a bundle ID separate from the release app. Pass `--data-root=<absolute path>` to the test executable, or set `SCOUT_DATA_ROOT` to that path. Use a fresh temporary directory for each run and keep simulation output in it too. Sessions, walkthroughs and the SDK bridge discovery file (`bridge.json`) follow this root. Apiary discovery is separate: use `--apiary-bridge=<file>` to point at an isolated mock discovery file when checking that integration. Do not point a test run at your everyday Scout data. See [data storage](architecture.md) for defaults and pruning behavior.

For example, launch your separately built test executable with a new root:

```bash
scout_test_root="$(mktemp -d /tmp/scout-check.XXXXXX)"
/path/to/Scout-Test.app/Contents/MacOS/Scout --data-root="$scout_test_root" --dry-run-delivery
```

Use `--dry-run-delivery` for simulations so they do not send tasks to live agents. The socket replay in `script/optimise/replay.py` uses a local mock and does not contact a model service.

## Review behavior

For task optimisation changes, check accept, undo and reopening a saved review. Confirm that manual edits invalidate stale proposals, that the original walkthrough asks remain intact, and that cancellation, failure and the full watchdog timeout leave the review unchanged. Wait for the spawned session's stop receipt before reporting completion. These checks cover asynchronous cleanup as well as visible results.

## Fixtures

The committed session, Linear, optimisation and walkthrough fixtures are synthetic examples. Fixture-generation scripts use fixed sample narration; they are not recordings of users or customer projects.

## Build checks

On a supported build machine, run `swift build && swift run scout-segment --check Fixtures/sessions` and build the native app with Xcode. Documentation-only changes can be checked by reviewing links, commands and their corresponding source definitions. This repository does not yet include a verification skill.
