# KPTN.SUB (working name)

A focused subtitle editor for macOS: the card list on the left, the video at top right, and the title bar and waveform at bottom right.

The code and Swift package are still called `Titles`; the working name only shows in the app for now.

## Build and run

You need macOS 14 (Sonoma) or later and Xcode 15 or later.

1. Open `Package.swift` in Xcode, using File ▸ Open… and choosing this folder's `Package.swift`.
2. Choose the **Titles** scheme and **My Mac** as the destination, then press **⌘R**.

Or, from Terminal in this folder: `swift run -c release`.

## Projects

Everything lives in a **project**, one per film: a single `.kptnsub` file (JSON) holding the film's videos (cuts, reels, trailers) and, for each video, every language.

- **New Project… (⌘N)** asks for a name, a folder (default `~/Movies/KPTN.SUB`, outside iCloud), the video, the master language and, optionally, an existing SRT. Pick a standard (General 17 CPS / 42 chars, Broadcast 15 / 37, Children's 13 / 37); **Advanced** covers reading speed, characters per line, lines, min/max duration, gap, frame rate, start timecode, frames or milliseconds, export format, BOM, line endings and file naming.
- **File ▸ Project Settings… (⌥⌘,)** changes those later. Each language can override reading speed and characters per line from its column menu.
- Projects **autosave**. A working copy is also kept in `~/Library/Application Support/KPTN.SUB`, with timestamped backups (the newest 30). If the project file is in iCloud and not downloaded, the app opens the working copy at once and shows a banner instead of waiting; if the two differ, it asks which to keep.
- The **Home** screen lists recent projects. **HOME** in the top strip (⇧⌘H) goes back there.
- The **video menu** in the top strip switches videos, adds a video file (⌥⌘N) or link (⌥⌘O), renames or removes one.

## Languages

Each video has a **master** language (★) and any number of others, shown side by side as card columns that scroll sideways.

- **Language ▸ New Language from Master…** makes a new language with the master's timecodes and empty text (or a copy of the text). It can be **free** (default: retime anything) or **locked** (🔒: master timing, text-only edits, follows master changes automatically).
- **Import Language…** reads an SRT or VTT and links each title to the master title it overlaps most.
- Rows line up by link, not by number, so an empty slot keeps later rows aligned. Double-click an empty slot, or select it and start typing, to make a title with that row's timing.
- Column headers have a menu: lock or unlock, make master, reading speed, characters per line, move left or right, close, delete. **+** reopens a closed column or adds one.
- **⌘L / ⇧⌘L** move focus to the next / previous language (wrapping), and **⌘1–⌘9** jump to a column, even while typing. The focused language is the one you edit, in the cards and the waveform.
- The waveform shows the other open languages as slim lanes above it. Click a lane to focus that language. The selected row is outlined in every lane.
- **Text Only (⇧⌘T)** hides picture and waveform, leaving the columns and a slim transport.
- Undo and redo (⌘Z / ⇧⌘Z) work across all languages in order. While paused, the playhead goes to what changed (half a second before a removed title).

## Supported files

| What | Formats |
| --- | --- |
| Video in | MP4, MOV, M4V (H.264, HEVC, ProRes), plus https links and HLS streams. MKV, WebM and AVI come with the libmpv engine later. |
| Subtitles in | SRT, WebVTT (New Project, Import Language, or drop onto the window). Encoding is detected (UTF-8, UTF-16, Windows-1252, Latin-1). |
| Subtitles out | **File ▸ Export… (⇧⌘E)**: this language or all languages, this video or all videos, SRT or WebVTT, named by the project pattern (default `{video}.{lang}`). Rows are renumbered on export. UTF-8, with optional BOM and CRLF. |

You can drop a video, a `.kptnsub` project or a subtitle file onto the window. Anything that can't be opened shows an alert explaining why.

When playback stops, the title under the playhead becomes the selected title.

## Controls

**Creating titles**

| Action | How |
| --- | --- |
| Draw a title | Drag across empty waveform. Its card opens for typing straight away. Drag again to make the next one. |
| Live spotting, Hold mode (default) | While the video plays, hold **↓** while a line is spoken. Key down sets the start and key up sets the end. |
| While spotting | A timer in the box's top right corner (and on the video) shows the length, coloured by the standard: amber while too short, periwinkle when fine, amber near the maximum, red over it. The card list scrolls to each new title. |
| Live spotting, Tap mode | **↓** ends the current title and starts the next. **↑** ends the current title and leaves a gap. |
| Spotting offsets | A title starts exactly where you press ↓ and ends exactly where you release it. Both can be offset in Settings (⌘,). |
| Split a title | Hold ⌘ over a box (the cursor turns into scissors) and click where it should split, or press ⌘B to split the title under the playhead. A gap of the standard's minimum (2 frames) is left, half on each side, and the text is divided at the nearest line break or word. |

**Fine-tuning**

| Action | Start | End |
| --- | --- | --- |
| Jog: hold the key and move the mouse. The cursor hides, and the video and audio scrub as you move. Release to lock and preview. | **Control** | **Option** |
| Coarse jog | Control + Shift | Option + Shift |
| Cancel a jog (while still holding) | Esc | Esc |
| Nudge 1 frame (Shift: 10) | Control + [ / ] | Option + [ / ] |
| Wheel or two-finger swipe: 1 frame per notch (Shift: 10) | Control + wheel | Option + wheel |
| Two-finger trackpad swipe over a box, no key (off by default; turn on under Title ▸ Trackpad Swipe Over a Title Adjusts Its Edges) | left half of the box | right half of the box |
| Mouse drag | box's left edge | box's right edge |

Dragging the body of a box moves the whole title. After adjusting an edge, the whole title plays from 1 s before its start to just after its end; turn this off separately for jogs/nudges and for drag-resizes in the Title menu. A plain scroll wheel, trackball or Shift+scroll only pans the waveform and never changes a title. Jogs and nudges stop at the neighbouring title, keeping a 2-frame gap. Mouse drags stop at the minimum gap from a neighbour; drag about 12 px further and it gives, so titles can overlap; overlapping titles turn lilac and are drawn one slightly higher and one slightly lower.

**Navigation**

| Key | Action |
| --- | --- |
| Shift+Space | Play / pause, from anywhere, even while typing (Space alone only types) |
| Tab / Shift+Tab | Next / previous title. The playhead jumps to it, and editing carries over if you were typing |
| ← / → | Step one frame back / forward (Shift: one second) |
| ↑ / ↓ while paused | Select the previous / next title and jump to it |
| Return, or just start typing | Edit the selected card's text (cursor at the end), or fill a selected empty slot |
| Return while typing | New line in the title (Esc or Tab leaves the card) |
| ⌥⌘B | Re-break the selected title's lines |
| ⌘L / ⇧⌘L, ⌘1–9 | Focus the next / previous language, or column 1–9 |
| Click a card | Select it, move the playhead to its start, and edit its text with the cursor at the end |
| Esc | Leave text editing |
| ⌫ (when not typing) | Delete the selected title |
| ⌘Z / ⇧⌘Z | Undo / redo |
| Scroll / two-finger swipe | Pan the waveform |
| ⌘ + scroll, or pinch | Zoom the waveform |
| Click the ruler | Seek |
| Right-click a box | Play, edit text, delete |
| Double-click a card's or box's number | Play that title |

During playback, the last title the playhead reached stays highlighted, and the card list scrolls to keep it centred. Starting playback leaves text editing.

**Settings (⌘,).** Jog speed (how fast Control/Option + mouse moves an edge), spotting mode, reaction offsets, the trackpad swipe option and the two replay options.

**Line breaks.** With Title ▸ Break Long Lines Automatically (on by default), a title too long for one line is broken when you leave its card, following the Netflix and BBC guides: break after punctuation or before a conjunction or preposition, never after an article, pronoun, auxiliary or preposition, keep names together, and prefer a shorter top line. English and Croatian (also Bosnian and Serbian) have word lists; other languages break at punctuation and for balance. Titles with your own line breaks are left alone.

**Waveform display.** Boxes show the full text of each title, wrapped to fit. The **Scale** slider makes quiet passages larger. The **dB** toggle shows loudness in decibels, so whispers stay visible next to loud sounds.

**Timing colours.** Periwinkle means OK, amber means close to the limit, and red means over the limit, for both reading speed (CPS) and duration. Limits come from the project's standard and each language's overrides.

## Code layout

```
Sources/Titles/
  TitlesApp.swift            app, window, menus
  Model/                     Subtitle, document + undo, SRT/VTT, Project/Track/rows, ProjectStore, AppModel
  Playback/                  PlaybackEngine protocol + AVFoundation engine (libmpv slots in here)
  Audio/                     audio decoding, waveform pyramid, scrub-audio grains
  Input/InputController.swift  modifier jog, nudges, wheel, spotting keys
  Views/                     theme, top strip, home, sheets, card columns, video pane, title bar, waveform
```

## Known limits

- Only the formats AVFoundation supports will play (see above).
- It runs as a Swift package, so it isn't sandboxed and isn't packaged for the App Store yet.
- Audio is decoded to 16 kHz mono in memory, about 230 MB for a 2-hour film.
- Columns are reordered from the column menu (Move Left / Right), not by dragging.
