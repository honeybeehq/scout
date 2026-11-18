# Releasing Scout

Releases are built, signed and notarized headless on a supported macOS 26 signing host with Xcode and XcodeGen. Nothing is launched there. Run app tests on a separate test Mac.

Scout updates itself with Sparkle 2. Sparkle is pinned to one exact version in `mac/project.yml` (`exactVersion`), and `script/verify-sparkle.sh` checks the resolved copy against the approved values in `mac/Sparkle.expected` before each build. The same script checks every other pin in `Package.resolved` against `mac/Packages.allowed`, one `identity version revision` line per approved package (today WhisperKit 1.1.1 and swift-argument-parser 1.7.0). A pin that isn't listed, or whose version or revision differs, fails the release. Only a project maintainer edits that list, after dependency review and approval; `--record` never touches it. The EdDSA private key that signs updates lives in the signing host’s login keychain and a private secret manager, never in the repo. Only the public key is committed.

## One-time setup on the signing host

Run these from the repo root on the supported signing host. Keep team operations and secret-manager configuration private.

1. Resolve Sparkle:

   ```sh
   xcodegen generate --spec mac/project.yml
   xcodebuild -resolvePackageDependencies -project mac/Scout.xcodeproj -scheme Scout -derivedDataPath build/release/DerivedData
   ```

2. Record what was resolved, and get it approved:

   ```sh
   script/verify-sparkle.sh --record
   ```

   It prints the Sparkle version, the git revision, the binary checksum declared in Sparkle's `Package.swift`, the SHA-256 of the extracted artifact, and the framework's signature state and CDHash, and writes all of them into `mac/Sparkle.expected`. It records first and reports problems after, so a first run always gives values to review. Sparkle's package artifact is ad-hoc signed, so it has no Team ID; release.sh checks that the embedded copy carries Scout's Team ID after Developer ID re-signing. Submit that output and the diff for maintainer verification against the upstream release. Record the package-integrity review before committing `mac/Sparkle.expected`. Then run it again without `--record`; it has to end with `Sparkle <version> verified.`

3. Generate the EdDSA key once, with the `generate_keys` from the verified artifact:

   ```sh
   tools="$(dirname "$(find build/release/DerivedData/SourcePackages/artifacts -type f -name generate_keys -path '*/bin/*' | head -n 1)")"
   "$tools/generate_keys" --account ed25519
   ```

   It stores the private key in the login keychain (the keychain must be unlocked) and prints the public key. If a key already exists, it prints that key and creates nothing. Never run it a second time with a new account.

4. Back up the private key using your configured secret manager's stdin write command:

   ```sh
   "$tools/generate_keys" --account ed25519 -x /dev/stdout | <configured-secret-manager-write-command>
   ```

   Keep the actual command and entry configuration private. Never write the private key into the repo or print it in logs. Releases normally read it from the login keychain; `SCOUT_SPARKLE_KEY_COMMAND` can supply it to `sign_update` through stdin instead.

5. Confirm the committed public configuration matches the signing key:

   ```yaml
   SCOUT_SPARKLE_PUBLIC_KEY: "AFkqB2WCeacpXMyiqIRiXE7wE6rYs0hPXwKFttPucXQ="
   SCOUT_FEED_URL: "https://github.com/honeybeehq/scout/releases/latest/download/appcast.xml"
   ```

   These values enable Sparkle. Updates become available when a signed release and its appcast are published.

## Each release

Build a release with one command, after reviewing the dry run:

```sh
script/release.sh --version X.Y.Z --dry-run
script/release.sh --version X.Y.Z
```

The default download base is `https://github.com/honeybeehq/scout/releases/download/v{version}`. Override it with `SCOUT_RELEASE_BASE_URL` if needed. The script downloads the latest published appcast with GitHub CLI and retains its items. No published release is fine for the first release; other download errors stop the run. Use `--previous-appcast FILE` for a local copy instead. GitHub CLI needs repository read access while the repository is private.

The script resolves and verifies dependency pins, checks the keychain public key, builds, signs, notarizes and staples, signs the update archive, and writes the appcast. Output is in `build/release/X.Y.Z/`, including notarization and verification logs. Without `--publish`, no artifacts leave the signing host except Apple notarization submissions. Appcast retrieval only reads GitHub.

To publish after maintainer approval:

```sh
script/release.sh --version X.Y.Z --publish --notes release-notes.md --dry-run
script/release.sh --version X.Y.Z --publish --notes release-notes.md
```

`--notes FILE` supplies release notes; omitting it generates installation and update instructions. Publishing requires GitHub CLI write access, PUBLIC repository visibility, an unused `vX.Y.Z` tag, and all verification steps passing in the same run. It creates the release and tag at the checkout's commit and uploads `Scout-X.Y.Z.dmg`, `Scout-X.Y.Z.zip`, `appcast.xml`, and `SHA256SUMS`. The script never changes repository visibility. Review and commit the version bump separately. Runtime installation and update checks belong on the separate test Mac.

## Changing the Sparkle version

Change `exactVersion` in `mac/project.yml`, empty `mac/Sparkle.expected`, and repeat setup steps 1 and 2, including maintainer approval and a recorded integrity review.

If a resolve changes Sparkle's recorded values for any other reason (for example after a rebase that touched `mac/project.yml`), `verify-sparkle.sh` fails with a MISMATCH. Re-record with `--record` and repeat maintainer review before committing. Don't edit `mac/Sparkle.expected` by hand to make it pass.

## Adding or changing another package

Submit the dependency and its provenance for contributor change review and maintainer approval first. Then pin it with `exactVersion` in `mac/project.yml`, resolve on the supported signing host, and add or change its line in `mac/Packages.allowed` by hand, with the version and revision from the resolved `Package.resolved`. Commit `Package.resolved` with it.
