---
name: vb
description: Voice Brother project quick-start. Use when user says /vb, "open voice bubble", "打开 voice bubble", or starts working on the Voice Brother macOS app. Navigates to the project, shows TODO status, and builds the app.
---

# Voice Brother Quick Start

Navigate to project, read TODO, build and launch.

## Steps

1. Set working directory:
   ```
   cd "~/IDE project/Voice Brother"
   ```

2. Read project instructions:
   - Read `CLAUDE.md` (build commands, architecture, known issues)
   - Read `TODO.md` (pending features and priorities)

3. Show a brief status summary to the user:
   - List incomplete TODO items (lines starting with `- [ ]`)
   - Note any known P0/P1 issues from CLAUDE.md

4. Build and launch:
   ```bash
   cd "~/IDE project/Voice Brother"
   xcodebuild build -project VoiceBrother.xcodeproj -scheme VoiceBrother -quiet 2>/dev/null
   pkill -x "VoiceBrother" 2>/dev/null || true
   sleep 1
   open "~/Library/Developer/Xcode/DerivedData/VoiceBrother-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBrother.app"
   ```

5. Report build result (success/failure) and confirm app launched.
