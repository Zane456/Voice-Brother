---
name: vb
description: Voice Bubble project quick-start. Use when user says /vb, "open voice bubble", "打开 voice bubble", or starts working on the Voice Bubble macOS app. Navigates to the project, shows TODO status, and builds the app.
---

# Voice Bubble Quick Start

Navigate to project, read TODO, build and launch.

## Steps

1. Set working directory:
   ```
   cd "/Users/zhangzheng/IDE project/Voice Bubble"
   ```

2. Read project instructions:
   - Read `CLAUDE.md` (build commands, architecture, known issues)
   - Read `TODO.md` (pending features and priorities)

3. Show a brief status summary to the user:
   - List incomplete TODO items (lines starting with `- [ ]`)
   - Note any known P0/P1 issues from CLAUDE.md

4. Build and launch:
   ```bash
   cd "/Users/zhangzheng/IDE project/Voice Bubble"
   xcodebuild build -project VoiceBubble.xcodeproj -scheme VoiceBubble -quiet 2>/dev/null
   pkill -x "VoiceBubble" 2>/dev/null || true
   sleep 1
   open "/Users/zhangzheng/Library/Developer/Xcode/DerivedData/VoiceBubble-arbvxvbxxsnfymbulsnszkqkgdon/Build/Products/Debug/VoiceBubble.app"
   ```

5. Report build result (success/failure) and confirm app launched.
