# Releasing Scout

Releases are built, signed and notarized headless on the Mac Studio, inside a Cell. Nothing is launched there. Every app test runs on a Mac mini.

Scout updates itself with Sparkle 2. Sparkle is pinned to one exact version in `mac/project.yml` (`exactVersion`), and `script/verify-sparkle.sh` checks the resolved copy against the approved values in `mac/Sparkle.expected` before each build. The EdDSA private key that signs updates lives in the Studio's login keychain and in Hem, never in the repo. Only the public key is committed.

## One-time setup on the Studio

Run these from the repo root in a Studio Cell.

1. Resolve Sparkle:

   ```sh
   xcodegen generate --spec mac/project.yml
   xcodebuild -resolvePackageDependencies -project mac/Scout.xcodeproj -scheme Scout -derivedDataPath build/release/DerivedData
   ```

2. Record what was resolved, and get it approved:

   ```sh
   script/verify-sparkle.sh --record
   ```

   It prints the Sparkle version, the git revision, the binary checksum declared in Sparkle's `Package.swift`, the SHA-256 of the extracted artifact, and the framework's signing authority and Team ID, then writes the first four values into `mac/Sparkle.expected`. Send that output and the diff to Tormod. He compares the version, revision and checksum with Sparkle's release page, and only after he approves do you commit `mac/Sparkle.expected`. Then run it again without `--record`; it has to end with `Sparkle <version> verified.`

3. Generate the EdDSA key once, with the `generate_keys` from the verified artifact:

   ```sh
   tools="$(dirname "$(find build/release/DerivedData/SourcePackages/artifacts -type f -name generate_keys -path '*/bin/*' | head -n 1)")"
   "$tools/generate_keys" --account ed25519
   ```

   It stores the private key in the login keychain (the keychain must be unlocked) and prints the public key. If a key already exists, it prints that key and creates nothing. Never run it a second time with a new account.

4. Store the private key in Hem as well. Export it straight into Hem's write command (look up the exact command with `hem --help`; don't guess an entry name, agree on one with Tormod):

   ```sh
   "$tools/generate_keys" --account ed25519 -x /dev/stdout | <hem write command for the entry>
   ```

   Never write the key into the repo or any file inside it. Print and save only the public key.

5. Put the public key and the feed URL into `mac/project.yml`:

   ```yaml
   SCOUT_SPARKLE_PUBLIC_KEY: <public key from step 3>
   SCOUT_FEED_URL: <https URL of appcast.xml, once hosting is decided>
   ```

   Both start empty. While either is empty, the app doesn't start Sparkle, and Check for Updates… stays disabled.

## Each release

Dry-run first, then run for real:

```sh
SCOUT_RELEASE_BASE_URL='https://<host>/<path>/v{version}' \
SCOUT_PREVIOUS_APPCAST=build/release/<last version>/appcast.xml \
script/release.sh --version X.Y.Z --dry-run

SCOUT_RELEASE_BASE_URL='https://<host>/<path>/v{version}' \
SCOUT_PREVIOUS_APPCAST=build/release/<last version>/appcast.xml \
script/release.sh --version X.Y.Z
```

`{version}` in the base URL is replaced with the version. Leave out `SCOUT_PREVIOUS_APPCAST` for the first release. To sign with the key from Hem instead of the keychain, set `SCOUT_SPARKLE_KEY_COMMAND` to the Hem read command; the key then goes to `sign_update` on stdin.

The script resolves packages, runs `verify-sparkle.sh` (and stops if it fails), checks that the keychain key matches `SCOUT_SPARKLE_PUBLIC_KEY`, builds, signs, notarizes and staples, signs the update zip with `sign_update`, and writes `appcast.xml`. Everything lands in `build/release/X.Y.Z/`: the DMG, `Scout-X.Y.Z.zip`, its `.eddsa` signature, `appcast.xml`, the notarization logs and `SHA256SUMS`. Nothing is published. Commit the version bump in `mac/project.yml` separately.

## Changing the Sparkle version

Change `exactVersion` in `mac/project.yml`, empty `mac/Sparkle.expected`, and repeat setup steps 1 and 2, including Tormod's approval.
