# Stable code signing for roon-key (Accessibility grant persistence)

## Problem

`codesign --sign -` (ad-hoc) gives every rebuild a fresh cdhash. Under macOS
13+, TCC keys Accessibility grants on cdhash for ad-hoc apps, so every
rebuild looks like a brand-new app to the system and re-prompts.

## Fix: self-signed code-signing certificate

One-time setup. TCC then keys grants on the certificate's designated
requirement, which is stable across rebuilds.

### 1. Create the certificate (Keychain Access GUI)

1. Open **Keychain Access**.
2. Menu: **Keychain Access** → **Certificate Assistant** → **Create a
   Certificate...**.
3. Name: `roon-key local` (or any name you'll recognize).
4. Identity Type: **Self Signed Root**.
5. Certificate Type: **Code Signing**.
6. Click **Create**.
7. Confirm it landed in the **login** keychain. Don't override defaults.

### 2. Point make-app.sh at it

Add to `~/.zshrc` (or whatever shell rc your interactive shell sources):

```sh
export ROON_KEY_SIGN_IDENTITY="roon-key local"
```

Open a new terminal so the export takes effect.

### 3. Rebuild and reinstall

```sh
launchctl unload ~/Library/LaunchAgents/com.roon-key.plist
./scripts/make-app.sh --install
launchctl load ~/Library/LaunchAgents/com.roon-key.plist
```

### 4. Re-grant Accessibility one last time

System Settings → Privacy & Security → Accessibility:

- Remove every existing `roon-key` entry (probably stale from ad-hoc builds).
- Re-add the fresh `/Applications/roon-key.app`.

From this point forward, rebuilds reuse the same code identity and the
Accessibility grant persists.

## Verification

```sh
codesign -dvvv /Applications/roon-key.app 2>&1 | grep -E 'Authority|Identifier|TeamIdentifier'
```

Look for `Authority=roon-key local` rather than `Signature=adhoc`.
