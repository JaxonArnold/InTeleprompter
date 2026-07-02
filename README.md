# InTeleprompter

An iOS teleprompter that records you while you read and follows your voice.

Point the front camera at yourself, present a script over the live preview, and record in up to 4K60 HEVC. With voice tracking enabled, the script scrolls as you speak: it keeps pace with your reading, pauses when you stop or ad-lib, and picks back up when you return to the script with no fixed scroll speed to fight.

## Features

**Prompter**
- Script overlays a live camera preview, with a reading guide line and edge fades
- Optional rule-of-thirds framing grid
- Tap-to-focus with continuous metering; long-press for a hard AE/AF lock, plus an exposure compensation slider
- Voice tracking: on-device speech recognition follows you through the script word by word
- Words dim as they're read, so you always know where the tracker thinks you are
- Manual mode with adjustable speed, drag to scrub, pinch to resize text
- Remote control from Bluetooth page-turner pedals, scrolling rings, and hardware keyboards: space plays/pauses, return starts/stops recording, arrows scrub, +/− adjusts speed
- Second iOS device as remote (MultipeerConnectivity): browse, pair with confirmation, and control the prompter from across the room
- Mirror mode for beam-splitter rigs: mirrored text fills the screen on black, camera preview hidden
- Portrait and landscape, with your reading position preserved through rotation

**Recording**
- Up to 4K at 60 fps, HEVC, with selectable quality tiers (4K/1080p × 60/30)
- Saved straight to your Photos library, plus instant in-app review of the last take
- Interruption-safe: phone calls, backgrounding, and camera conflicts finish and save the take instead of losing it
- Storage checks before recording and thermal-aware quality capping on hot devices

**Scripts**
- Simple script library with editor, word counts, and estimated read times
- Inline formatting: **bold**, *italic*, [red]color[/red] highlights, and SPEAKER: cues — auto-colored per name and skipped by voice tracking
- Import from Files (PDF, Word .docx, RTF, Markdown, plain text) or paste from the clipboard
- Share sheet extension: send text or files straight from Notes, Safari, Mail, and Google Docs (Share & export → Send a copy → Word/.docx)
- Stored locally, encrypted at rest

## Voice tracking, briefly

Live transcription is fuzzy-matched against the script within a sliding window around the current position. Single words can only advance the position a few steps; larger jumps require consecutive-word evidence, so ad-libbing doesn't yank the script around. When you go quiet and come back, at the same spot, a few words earlier, or somewhere ahead, the matcher re-anchors within a word or two. A watchdog restarts the recognition task if it stalls during long sessions.

Speech recognition runs on-device whenever the language supports it. The app makes no network calls of its own.

## Requirements

- iOS 17.6+
- Xcode 26 or later to build
- A physical device for anything camera- or speech-related (the simulator has neither)

No third-party dependencies.

## Building

Open `InTeleprompter.xcodeproj`, select your team for signing, and run on a device. Tests (`⌘U`) cover the script tokenizer and the voice-tracking matcher, including the regression scenarios for fast reading, off-script recovery, and transcript revisions.

## Permissions

| Permission | Used for |
|---|---|
| Camera | The live preview and recording |
| Microphone | Recording audio and voice tracking |
| Speech recognition | Following your voice through the script |
| Photos (add only) | Saving finished takes |
| Local network | Controlling the prompter from a second iPhone or iPad |

