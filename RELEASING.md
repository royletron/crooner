# Releasing Crooner

Releases are fully automated. The procedure is as follows:

1. Merge a pull request into `main` that carries one of these labels:

   | Label | Semver bump |
   |---|---|
   | `release: patch` | `x.y.Z+1` — bug fixes |
   | `release: minor` | `x.Y+1.0` — new features |
   | `release: major` | `X+1.0.0` — breaking changes |

2. That is the entirety of your obligation.

GitHub Actions will compute the next version from the highest existing tag,
push a new `vX.Y.Z` tag, build a signed and notarised DMG, and publish it
as a GitHub Release with automatically generated notes drawn from every PR
merged since the previous release.

---

## Re-running a failed build

Should the workflow suffer some mechanical misfortune after the tag has
already been pushed, visit:

**Actions → Release → Run workflow**

Supply the existing tag (e.g. `v1.2.3`) and the build will proceed without
creating a duplicate tag.

---

## Required repository secrets

These must be configured once under **Settings → Secrets → Actions**:

| Secret | Description |
|---|---|
| `APPLE_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Any strong password — used for the ephemeral CI keychain |
| `APPLE_ID` | Apple ID email used for notarisation |
| `APPLE_APP_PASSWORD` | App-specific password for notarisation |
| `APPLE_TEAM_ID` | 10-character Apple Developer team identifier |

To encode your certificate:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the result directly into the secret — no newlines, no wrapping.

---

## Local development builds

No signing or notarisation is required for local development. Simply:

```bash
brew install xcodegen
xcodegen generate
open Crooner.xcodeproj
```

Build and run with your own development certificate. macOS will prompt for
permissions on first launch as it would for any unsigned local build.
