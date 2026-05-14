# Design prompts for RoonBridge and RoonTrol

Prompts to feed into ChatGPT (GPT-4o image gen) in three sequential chats.
Numbering reflects order within each chat.

## Chat 1: RoonBridge (start a new chat)

1. `01-roonbridge-icon.md` - opening message, generates the app icon
2. `02-roonbridge-banner.md` - after locking the icon
3. `03-roonbridge-wordmark.md` - after the banner

## Chat 2: RoonTrol (new chat; upload the finalized RoonBridge icon)

1. `04-roontrol-icon.md` - opening message
2. `05-roontrol-menubar.md` - after locking the icon
3. `06-roontrol-banner.md` - after the menubar glyph
4. `07-roontrol-wordmark.md` - after the banner

## Chat 3: Family banner (new chat; upload BOTH finalized icons)

1. `08-family-banner.md` - opening message, generates the paired hero

## Quick paste

Each file is plain markdown. To copy any prompt to the clipboard:

```
pbcopy < 01-roonbridge-icon.md
```

## Final delivery paths

```
assets/roonbridge/icon-1024.png
assets/roonbridge/banner.png
assets/roonbridge/wordmark.png
assets/roontrol/icon-1024.png
assets/roontrol/icon-menubar.png
assets/roontrol/banner.png
assets/roontrol/wordmark.png
assets/family-banner.png
assets/family-banner-og.png
```
