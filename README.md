# Titles — build 1

A focused subtitle editor for macOS: the card list on the left, the video at top right, and the title bar and waveform at bottom right.

## Build and run

You need macOS 14 (Sonoma) or later and Xcode 15 or later.

1. Open `Package.swift` in Xcode, using File ▸ Open… and choosing this folder's `Package.swift`.
2. Choose the **Titles** scheme and **My Mac** as the destination, then press **⌘R**.

Or, from Terminal in this folder: `swift run -c release`.

## Supported files

| What | Formats |
| --- | --- |
| Video in | MP4, MOV, M4V (H.264, HEVC, ProRes), plus https links and HLS streams via ⌥⌘O. MKV, WebM and AVI come with the libmpv engine in build 2. |
| Subtitles in | SRT, WebVTT. Encoding is detected (UTF-8, UTF-16, Windows-1252, Latin-1). |
| Subtitles out | SRT (⌘S), WebVTT (⇧⌘E). Always written as UTF-8. |

You can also drop a video and/or an `.srt` file onto the window.

## Controls

**Creating titles**

| Action | How |
| --- | --- |
| Draw a title | Drag across empty waveform. Its card opens for typing straight away. Drag again to make the next one. |
| Live spotting, Hold mode (default) | While the video plays, hold **↓** while a line is spoken. Key down sets the start and key up sets the end. |
| Live spotting, Tap mode | **↓** ends the current title and starts the next. **↑** ends the current title and leaves a gap. |
| Reaction offset | 250 ms is subtracted from every spotting key press. |

**Fine-tuning**

| Action | Start | End |
| --- | --- | --- |
| Jog: hold the key and move the mouse. The cursor hides, and the video and audio scrub as you move. Release to lock and preview. | **Control** | **Option** |
| Coarse jog | Control + Shift | Option + Shift |
| Cancel a jog (while still holding) | Esc | Esc |
| Nudge 1 frame (Shift: 10) | Control + [ / ] | Option + [ / ] |
| Wheel or two-finger swipe: 1 frame per notch (Shift: 10) | Control + wheel | Option + wheel |
| Two-finger swipe over a box, no key | left half of the box | right half of the box |
| Mouse drag | box's left edge | box's right edge |

Dragging the body of a box moves the whole title. After a change, the start preview plays from 1 s before to 1 s after the start, and the end preview plays from 1 s before to 0.5 s after the end. Jogs and nudges stop at the neighbouring title, keeping a 2-frame gap. Mouse drags can overlap a neighbour; overlapping titles turn lilac and are drawn one slightly higher and one slightly lower.

**Navigation**

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Step one frame back / forward (Shift: one second) |
| ↑ / ↓ while paused | Select the previous / next title and jump to it |
| Return | Edit the selected card's text |
| Esc | Leave text editing |
| ⌫ (when not typing) | Delete the selected title |
| ⌘Z / ⇧⌘Z | Undo / redo |
| Scroll / two-finger swipe | Pan the waveform |
| ⌘ + scroll, or pinch | Zoom the waveform |
| Click the ruler | Seek |
| Right-click a box | Play, edit text, delete |

**Waveform display.** The **Scale** slider makes quiet passages larger. The **dB** toggle shows loudness in decibels, so whispers stay visible next to loud sounds.

**Timing colours.** Periwinkle means OK, amber means close to the limit, and red means over the limit, for both reading speed (CPS) and duration. Change the preset under Title ▸ Timing Preset.

## Code layout

```
Sources/Titles/
  TitlesApp.swift            app, window, menus
  Model/                     Subtitle, document + undo, SRT/VTT, AppModel (all editing actions)
  Playback/                  PlaybackEngine protocol + AVFoundation engine (libmpv slots in here)
  Audio/                     audio decoding, waveform pyramid, scrub-audio grains
  Input/InputController.swift  modifier jog, nudges, wheel, spotting keys
  Views/                     theme, card pane, video pane, title bar, waveform
```

## Known limits of build 1

- Only the formats AVFoundation supports will play (see above).
- It runs as a Swift package, so it isn't sandboxed and isn't packaged for the App Store yet.
- Audio is decoded to 16 kHz mono in memory, about 230 MB for a 2-hour film.
- Settings (preset, spotting mode, offset) aren't saved between launches yet.
