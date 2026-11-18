# Building from source

Most people should [install the release DMG](install.md). Build from source if you want to change Scout or try unreleased work.

Requirements: macOS 26, Xcode 26, XcodeGen (`brew install xcodegen`).

```bash
./script/build_and_run.sh                       # build, sign, stage at ~/Applications/Scout.app, launch
./script/build_and_run.sh --reset-onboarding    # start onboarding from the first step
./script/build_and_run.sh --onboarding-step=voice
./script/build_and_run.sh --build-only
```

Before building, set `DEVELOPMENT_TEAM` in your local `mac/project.yml` to your own Apple Developer Team ID and make sure your Apple Development signing identity is available in Xcode. The checked-in team belongs to the maintainers; contributors need their own signing setup. Keep this local signing change out of your contribution.

`build_and_run.sh` quits any running Scout, replaces `~/Applications/Scout.app` and signs it with that development identity, so macOS permission grants survive rebuilds. Set `SCOUT_STAGED_APP` to stage somewhere else.

Maintainer releases use separate Developer ID signing and notarization through `script/release.sh`. Contributor builds do not need the maintainer release certificate or notarization credentials.

## Next

- [Contributor checks](../contributing.md): keep test data apart from your everyday Scout data, and the checks to run before a change.
- [Developer checks in the README](../../README.md#developer-checks): simulated sessions, galleries and end-to-end runs without a human at the machine.
- [Architecture](../architecture.md) and [releasing](../releasing.md).
