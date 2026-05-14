# Design session context

## Goal

Brand assets for RoonBridge + RoonTrol (sibling apps). RoonTrol = "troll living under the bridge" - pun on control / Roon troll.

## Locked palette (sampled from Roon UI in sRGB)

- Primary purple: `#6062BB` (Roon's darker popup UI)
- Dark-variant gradient bottom: `#5455A1`
- Off-white background: `#F2ECF6` (Roon's lavender-tinted white)
- Accent gold (RoonTrol troll-eyes only, NOT in Roon palette): `#C9A24B`

## Bridge concept

Fantasy stone bridge, side elevation (riverbank view). User picked Variation 3 from the first stone-bridge contact sheet:
- Broad sturdy arch occupying ~70% of icon width
- Chunky abutments anchoring both sides
- Hand-built irregular top edge (subtle, not amplified)
- Generous tall arch opening (where the troll will live in the sibling)
- Voussoirs along the full arch curve
- Solid stone spandrels (originally had speckled stone fragments - we want clean spandrels)

## Iteration history (key lessons)

- ~10 rounds of verbal refinement in ChatGPT each drifted V3 toward thinner/cleaner/more symmetric
- Two specific failure modes:
  - Model interprets "refine" as "elegantize and slim"
  - Model interprets "clean spandrels" as "remove spandrels entirely" - producing a freestanding arch instead of a bridge
- GPT-4o image gen cannot reliably upscale (regenerates instead) or hold style across edits
- **Verbal correction in ChatGPT is exhausted**; user pivoted to extracting V3 from the original contact sheet in Photoshop

## Current state

- V3 extracted cleanly in Photoshop, saved at 266x266
- Crop reference: `/Users/monty/.claude/image-cache/08566ab6-2280-4508-b51c-fd90e4faef28/27.png`
- Need to upscale to ~1024 for proper icon master

## Pending immediate step

User runs the 266x266 crop through one of:
1. **Photoshop's Preserve Details 2.0** (already in PS, try first)
2. **Upscayl** (free, brew/dmg, Digital Art model, 4x) - fallback if PS result is soft

After upscale, save result to `/Users/monty/dl/` and tell me to inspect before continuing.

## Photoshop edit sequence (after upscale lands)

1. Recolor bridge from current indigo to `#6062BB` (Color Range -> Fill)
2. Recolor background from cream to `#F2ECF6` (Magic Wand -> Fill)
3. Paint over spandrel speckles with `#F2ECF6` (keep arch outline, voussoirs, abutments untouched)
4. Save as `RoonBridge-icon-light.png` in `/Users/monty/dev/roon-key/design/masters/`
5. Duplicate, invert colors (or swap with Color Range)
6. Add vertical gradient on bg: `#6062BB` top -> `#5455A1` bottom
7. Save as `RoonBridge-icon-dark.png`

## Workflow after RoonBridge icon ships

1. RoonBridge banner (1280x640, mark + wordmark in Grifo display serif)
2. RoonBridge wordmark (1600x400 transparent + dark-bg variant)
3. RoonTrol icon (NEW chat, attach finished RoonBridge icon as sibling reference)
4. RoonTrol menubar glyph (silhouette for `Resources/Icons/MenubarIcon.png`)
5. RoonTrol banner + wordmark
6. Family banner (third chat, upload both icons): "RoonBridge runs on the Roon Core. RoonTrol is the troll living under it."

## Prompt files

`/Users/monty/dev/roon-key/design/prompts/` - 9 numbered files for the planned 3-chat workflow. Most are now superseded by the manual-edit plan but the banner/wordmark/RoonTrol prompts (02-08) remain useful as the workflow advances.

## Tool decisions

- **Photoshop**: doing the recolor + spandrel cleanup edits, possibly the upscale
- **Upscayl**: backup upscaler if PS Preserve Details is soft
- **ImageMagick**: NOT for this upscale (wrong shape for 4x on illustrations). Keep for the downscale ladder (`magick master.png -filter Mitchell -resize 32x32 out.png`) when building the iconset
- **GPT-4o image gen**: closed for the bridge icon - drift unreliable. Possibly still useful for RoonTrol troll (new subject) and banner compositions (different task) but with caution

## Decisions already made and not to relitigate

- Roon-purple family (not deeper navy, not brighter violet)
- Side elevation (riverbank view, not deck-on view)
- Fantasy stone bridge (not modern suspension, not abstract)
- V3 specifically (not V1, V2, V4 from cleanup pass)
- Light + dark variant pair for every icon
