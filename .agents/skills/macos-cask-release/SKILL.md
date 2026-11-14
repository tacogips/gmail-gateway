---
name: macos-cask-release
description: Deprecated for this Swift project. Use only to recognize that the old signed Homebrew Cask workflow has been removed; do not build, sign, notarize, render, publish, or recreate a mail-gateway Cask unless the user explicitly asks to design a new Cask workflow.
---

# macOS Cask Release

The Cask workflow was removed when Homebrew installation moved to three
independently installable Formulae:

- `mail-gateway-reader`
- `mail-gateway-draft`
- `mail-gateway-sender`

Use `.agents/skills/homebrew-release/SKILL.md` for release work.

Do not look for `scripts/build-homebrew-cask-release.sh`,
`scripts/render-homebrew-cask.sh`, or `release:homebrew-cask-local`; they are no
longer part of the active release contract. If a user asks for a Cask again,
treat it as new design work and preserve the split command names rather than
restoring the legacy single `mail-gateway` Cask.
