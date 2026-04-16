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
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing update archives (see below) |

To encode your certificate:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

Paste the result directly into the secret — no newlines, no wrapping.

---

## One-time Sparkle key setup

Sparkle uses EdDSA (ed25519) to verify that update archives haven't been tampered
with.  You need to generate a key pair **once**, store the private key as a secret,
and embed the public key in the app.

### 1 — Download the Sparkle CLI

```bash
SPARKLE_VER="2.7.5"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz" \
  | tar xJ --strip-components=0 -C /tmp
```

### 2 — Generate the key pair

```bash
/tmp/bin/generate_keys
```

The tool will:
- Store the **private** key in your macOS keychain under the account `ed25519`.
- Print the **public** key as a Base64 string — copy it.

### 3 — Export the private key for CI

`generate_keys` stores the private key in your macOS Keychain under the label
`ed25519`.  Retrieve it with:

```bash
security find-generic-password -a "ed25519" -s "ed25519" -w | pbcopy
```

Paste the result into a new repository secret named **`SPARKLE_PRIVATE_KEY`**.

> If the above `security` command returns nothing, `generate_keys` may have used a
> different service name.  Check **Keychain Access → login → Passwords** and look
> for an entry that contains "sparkle" or "ed25519".

### 4 — Embed the public key in the app

Open `project.yml` and replace the `SUPublicEDKey` placeholder with the public
key you copied in step 2:

```yaml
        SUPublicEDKey: "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789..."
```

Run `xcodegen generate` to regenerate the Xcode project.

> **Never commit the private key.**  Only the public key lives in the repository.

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
