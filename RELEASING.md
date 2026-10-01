# Releasing GhostHand

GhostHand ships two independent desktop artifacts. Both must be **signed** before they can be
distributed without scary OS warnings: macOS requires notarisation, Windows requires a code-signing
certificate. Neither store is required — these are direct downloads — but the operating systems
gate unsigned binaries.

`release.yml` automates all of this on a `v*` tag. Signing steps are **conditional**: if the
relevant secrets are absent the job still builds and uploads unsigned artifacts rather than failing,
so a fork can cut a test release.

---

## Artifacts produced

| Platform | File | Notes |
|---|---|---|
| Windows x64 | `GhostHand-<tag>-win-x64.zip` | self-contained, ReadyToRun |
| Windows ARM64 | `GhostHand-<tag>-win-arm64.zip` | self-contained, ReadyToRun |
| macOS | `GhostHand-<tag>-macos-universal.zip` | universal (x86_64 + arm64), notarised |
| Supply chain | `GhostHand-<tag>-sbom.spdx.json` | SPDX SBOM |
| Supply chain | `SHA256SUMS` | checksums for every artifact |

---

## Accounts and certificates you must supply

These cannot be installed or automated away — they are external accounts.

### macOS

| Item | Where it comes from | Cost |
|---|---|---|
| Apple Developer Program membership | developer.apple.com | $99/year |
| **Developer ID Application** certificate (`.p12`) | Xcode → Settings → Accounts → Manage Certificates, exported with a password | included with membership |
| Apple ID + app-specific password | appleid.apple.com | free |
| Team ID | developer.apple.com → Membership | free |

### Windows

| Item | Where it comes from | Cost |
|---|---|---|
| Code-signing certificate | [Azure Trusted Signing](https://learn.microsoft.com/azure/trusted-signing/) (recommended) or an OV/EV `.pfx` from a CA | from ~$10/month (Azure) or ~$200–400/year (EV) |

> Note: since June 2023 all Windows code-signing certificates require an HSM or cloud signing
> service. A plain `.pfx` file can no longer be issued for a new OV certificate, so Azure Trusted
> Signing is the path of least resistance.

---

## GitHub Actions secrets

Set these under **Settings → Secrets and variables → Actions**. All are optional; omitting them
produces unsigned artifacts.

| Secret | Used for |
|---|---|
| `APPLE_CERT_P12_BASE64` | base64 of the Developer ID `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `APPLE_CERT_PASSWORD` | password chosen when exporting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email for `notarytool` |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_PASSWORD` | app-specific password for `notarytool` |
| `KEYCHAIN_PASSWORD` | any random string; used for the temporary CI keychain |
| `WINDOWS_CERT_PFX_BASE64` | base64 of the Windows signing `.pfx` (if not using Azure) |
| `WINDOWS_CERT_PASSWORD` | password for that `.pfx` |

---

## Manual macOS release (local, for testing)

```bash
cd macos

# 1. Universal build (ad-hoc signed by the build script).
GHOSTHAND_ARCHS="x86_64 arm64" Scripts/make-app-bundle.sh -c release

# 2. Re-sign everything with the Developer ID + hardened runtime.
ID="Developer ID Application: Your Name (TEAMID)"
codesign --force --options runtime --timestamp --sign "$ID" \
  dist/GhostHand.app/Contents/MacOS/ghosthand
codesign --force --options runtime --timestamp --sign "$ID" \
  dist/GhostHand.app/Contents/MacOS/GhostHandApp
codesign --force --options runtime --timestamp \
  --entitlements Resources/GhostHand.entitlements --sign "$ID" \
  dist/GhostHand.app

# 3. Verify the signature before notarising.
codesign --verify --deep --strict --verbose=2 dist/GhostHand.app

# 4. Package and notarise.
ditto -c -k --keepParent dist/GhostHand.app GhostHand-macos-universal.zip
xcrun notarytool submit GhostHand-macos-universal.zip \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" --wait

# 5. Staple the ticket so it works offline.
xcrun stapler staple dist/GhostHand.app
spctl -a -vvv -t install dist/GhostHand.app     # expect: accepted, source=Notarized Developer ID
```

`--options runtime` (hardened runtime) is mandatory for notarisation. The entitlements file is
required because the hardened runtime blocks microphone/speech access without it.

### macOS gotchas

- **Ad-hoc signature is replaced, not layered.** `make-app-bundle.sh` ad-hoc signs the bundle; the
  Developer ID signature must use `--force`.
- **Sign nested code before the bundle.** The bundle contains two Mach-O executables
  (`GhostHandApp`, `ghosthand`); sign them first, then the `.app`. Avoid `--deep` for distribution —
  Apple treats it as a diagnostic escape hatch, not a signing strategy.
- **Notarisation is a per-artifact round trip.** Archive, submit the archive, wait, *then* staple the
  `.app` and re-archive the stapled copy for distribution.
- **Intel runners are going away.** GitHub is dropping macOS x86_64 runners in 2027; the workflow
  builds a universal binary on an arm64 runner so the artifact is future-proof either way.

---

## Manual Windows release (local, for testing)

```powershell
dotnet publish windows/src/GhostHand.App/GhostHand.App.csproj -c Release -r win-x64 `
  --self-contained true -p:PublishReadyToRun=true -o dist/GhostHand-win-x64
dotnet publish windows/src/GhostHand.Cli/GhostHand.Cli.csproj -c Release -r win-x64 `
  --self-contained true -p:PublishReadyToRun=true -o dist/GhostHand-win-x64

# Sign every executable and DLL that ships (Azure Trusted Signing shown in the workflow).
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
  /f cert.pfx /p "$env:WINDOWS_CERT_PASSWORD" dist/GhostHand-win-x64/GhostHand.App.exe
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
  /f cert.pfx /p "$env:WINDOWS_CERT_PASSWORD" dist/GhostHand-win-x64/GhostHand.Cli.exe

Compress-Archive -Path dist/GhostHand-win-x64/* -DestinationPath GhostHand-win-x64.zip -Force
```

Always timestamp (`/tr /td`) so signatures remain valid after the certificate expires.

---

## Supply chain

The release job generates an SPDX SBOM with [syft](https://github.com/anchore/syft)
(`brew install syft`) and a `SHA256SUMS` file. Optionally sign the checksums with
[cosign](https://github.com/sigstore/cosign) (`brew install cosign`) using keyless OIDC signing so
consumers can verify provenance:

```bash
cosign sign-blob --yes SHA256SUMS > SHA256SUMS.sig
```

---

## Versioning checklist

1. Bump the version in `macos/Resources/Info.plist` (`CFBundleShortVersionString`).
2. Make sure `README.md` and `macos/README.md` describe current behaviour.
3. Tag `vX.Y.Z` and push the tag — that triggers `release.yml`.
4. Verify each artifact on a clean machine:
   - Windows: run `GhostHand.Cli.exe check`.
   - macOS: `spctl -a -vvv -t install GhostHand.app` and launch it, granting Accessibility.
