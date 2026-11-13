# KPTN.SUB (working name)

A focused subtitle editor for macOS: the card list on the left, the video at top right, and the title bar and waveform at bottom right.

The code and Swift package are still called `Titles`; the working name only shows in the app for now.

## Standalone app for testing

`scripts/package-app.sh [folder]` builds a universal (Apple Silicon + Intel) release, wraps it as `KPTN.SUB.app`, self-signs it and zips it (default: Desktop). Copy it to any Mac with macOS 14 or later, no Xcode needed. The first launch on each Mac is blocked until you choose System Settings ▸ Privacy & Security ▸ Open Anyway.

## Build and run

You need macOS 14 (Sonoma) or later and Xcode 15 or later.

1. Open `Package.swift` in Xcode, using File ▸ Open… and choosing this folder's `Package.swift`.
2. Choose the **Titles** scheme and **My Mac** as the destination, then press **⌘R**.

Or, from Terminal in this folder: `swift run -c release`.

## Projects

Everything lives in a **project**, one per film: a single `.kptnsub` file (JSON) holding the film's videos (cuts, reels, trailers) and, for each video, every language.

- **New Project… (⌘N)** asks for a name, a folder (default `~/Movies/KPTN.SUB`, outside iCloud), the video, the master language and, optionally, an existing SRT. Pick a standard (General 17 CPS / 42 chars, Broadcast 15 / 37, Children's 13 / 37); **Advanced** covers reading speed, characters per line, lines, min/max duration, gap, frame rate, start timecode, frames or milliseconds, export format, BOM, line endings and file naming.
- **File ▸ Project Settings… (⌥⌘,)** changes those later. Each language can override reading speed, characters per line and lines in its **Language Options…**.
- Projects **autosave**. A working copy is also kept in `~/Library/Application Support/KPTN.SUB`, with timestamped backups (the newest 30). If the project file is in iCloud and not downloaded, the app opens the working copy at once and shows a banner instead of waiting; if the two differ, it asks which to keep.
- The **Home** screen lists recent projects. **HOME** in the top strip (⇧⌘H) goes back there.
- The **video menu** in the top strip switches videos, adds a video file (⌥⌘N) or link (⌥⌘O), renames or removes one.

## Languages

Each video has a **master** language (★) and any number of others, shown side by side as card columns that scroll sideways.

- **Language ▸ New Language from Master…** makes a new language with the master's timecodes and empty text (or a copy of the text). It can be **free** (default: retime anything) or **locked** (🔒: master timing, text-only edits, follows master changes automatically).
- **Import Language…** reads an SRT or VTT and links each title to the master title it overlaps most.
- Rows line up by link, not by number, so an empty slot keeps later rows aligned. Double-click an empty slot, or select it and start typing, to make a title with that row's timing.
- Column headers have a menu (⋯ or right-click): **Language Options…**, lock or unlock, make master, move left or right, close, delete. **+** reopens a closed column or adds one.
- **Language Options…** changes which language a column is (from the list, or any code and name; spell check, line breaking and the export file name follow, and the project words go along), makes it the master or sets free/locked timing, sets its own reading speed, characters per line and lines, turns spell check on or off for that language, with its project words listed to review or remove, and sets how it exports: UTF-8 or an older code page (Windows-1250 Central European, 1251 Cyrillic, 1252–1257, 874 Thai; characters a code page can't hold become “?” and export says how many), and for right-to-left languages (Arabic, Hebrew, Persian…) right-to-left marks on each line so punctuation lands on the correct side.
- **⌘L / ⇧⌘L** move focus to the next / previous language (wrapping), and **⌘1–⌘9** jump to a column, even while typing. The focused language is the one you edit, in the cards and the waveform.
- The waveform shows the other open languages as slim lanes above it. Click a lane to focus that language. The selected row is outlined in every lane.
- **Text Only (⇧⌘T)** hides picture and waveform, leaving the columns and a slim transport.
- Undo and redo (⌘Z / ⇧⌘Z) work across all languages in order. While paused, the playhead goes to what changed (half a second before a removed title).

## Coming in the next build

- **A small "esc" while you type.** The card with the text cursor shows a little "esc" key on the lower edge of its text box. Esc takes the cursor out; then ⌘I makes the whole title italic again, ⌘V pastes at its end, and Tab, ⌘I runs through titles quickly.
- **Language Options…** in each language's menu: change the language (or its code and name), master and timing, its own reading speed, characters per line and lines, spell check with its project words, and export text encoding (UTF-8 or an older Windows code page) plus right-to-left marks for Arabic, Hebrew and Persian.
- **Replay after moving a title is now a setting.** Title ▸ Replay Title After Drag-Move (on by default, also in Settings), next to the jog and drag-resize replays.
- **Space puts the cursor back in the card.** With no cursor active (after Esc), Space puts it at the end of the selected title's text, without typing a space. Shift+Space still plays and pauses.
- **Shift+Tab goes back to the start of this title first**, like a player's Back button; pressed again at the start (or right after tabbing onto it), it goes to the previous title.
- **Italics show on the waveform.** Italic (and bold) words in a title are drawn that way in its waveform box too, as in the card.

## New in 0.30

- **An all-italic title stays italic when you clear it.** Delete all the text of a title that's italic throughout (voice-over, songs) and the empty card keeps italics, with a small **I** badge; what you type or paste next is italic. ⌘I in the empty card turns it off. Titles with only some words in italics start plain again, and a new title never inherits italics.
- **Misspelled words keep their red underline** when you click or arrow onto them; the mark goes only when the spelling is fixed. Only the word you're typing at that moment waits until you move on.
- **Selected title on the waveform: amber brackets.** Instead of a full amber frame, rounded LCARS-style brackets hold the left and right fifth of the box, each prong ending in a small capsule like the one beside the pane titles. The top and bottom edges in between keep the title's own timing colour. The frame runs along the middle of the brackets, so none of it shows through, and the brackets' outer edge is the box's real edge (where you grab it). Boxes have slightly rounder corners.

## New in 0.29

- **Find and Replace.** ⌘F opens a Find bar above the cards (⌥⌘F with Replace). Return or ⌘G goes to the next match, ⇧⌘G to the previous; Esc closes it. It searches what a viewer reads, so tags never get in the way, and a phrase broken over two lines is still found. Choose This Language, All Open Languages or Selected Titles; Match Case and Whole Word are optional. Replace does one and moves on; All replaces every match, one undo step per language. Matches show in teal on the cards, in the card being edited, and as a bar under waveform boxes. Replacing keeps formatting (italic text stays italic).
- **Spell check.** Misspelled words get a red dotted underline in the cards and while typing. Right-click one in the card you're editing for suggestions, Learn Spelling (every project) or Add to Project Words (names and places in this film, saved in the project). ⌘; goes to the next title with a misspelling. Edit ▸ Check Spelling turns it off. Each language is checked in its own language: the Mac's dictionaries cover English, Polish, Portuguese, German, French, Spanish, Russian and about 40 more; Croatian, Serbian (both alphabets), Bosnian, Persian and Thai use open-source Hunspell dictionaries (`bash scripts/fetch-dictionaries.sh` downloads them into `~/Library/Application Support/KPTN.SUB/Dictionaries`; Edit ▸ Show Dictionaries Folder; a build made with `package-app.sh` carries them inside the app). A language's menu (… in its column header) says which dictionary checks it. Japanese, Chinese and Korean aren't checked.
- **Italics behave.** Once italics are on, they stay on as you type: the text shrinking to fit, a line re-breaking, the CPS colour changing, clicking away or playing no longer switch them off. ⌘I in an empty card works first time. ⌘I on a selected title you aren't typing in makes the whole title italic (or plain again); on an empty one, what you type or paste next is italic. Typing into a selected italic title carries on in italics.
- **Paste into the selected title** even when the waveform was clicked last (copying lines from a dialogue list): ⌘V puts the text at the end and breaks the lines by the rules. ⌘I then ⌘V pastes it in italics.
- **Deleting a title takes Control-Delete** (⌃⌫ or ⌃⌦), so a stray Delete can't lose one. Plain Delete only reminds you. Right-click ▸ Delete Title on a box still works.
- **Drawing a title stops at the minimum gap** from its neighbours, like stretching one does; pull on about 16 px to overlap. Starting a drag inside the gap starts it at the gap's edge.
- **Selection and warning colours no longer clash.** A selected box keeps its timing colour (0.30: inside amber brackets); amber now means only "selected". Near the limit is pale gold everywhere (cards, chips, waveform, spotting timer).

## Since the build of 2026-11-09

- **Rows by time.** Card rows are built from timing alone: titles from different languages that start within 0.25 s, or overlap for half their length, share a row. Moving a title never reorders another language. Each language is numbered on its own.
- **Formatting.** `<i>`, `<b>` and `<u>` show as italic, bold and underline in cards and on the video; tags don't count towards CPS or characters per line. ⌘I wraps the selection in `<i>…</i>` while typing.
- **Typing.** Shift+Space plays unless you typed a letter while holding Shift (a capital then a space). Tab puts the cursor at the end of the next card. Hover a column's coloured cap to close it.
- **Formatting.** Cards show and edit italics, bold and underline as they look (⌘I toggles italic); the file keeps the tags.
- **Line breaks while typing.** When a line runs past the limit, the title is re-broken by the rules as you type; leaving the card evens the lines out, unless you broke them yourself with Return. Title ▸ Re-break All Lines (⇧⌥⌘B) does every title in the focused language.
- **Waveform.** Clicking a title moves the playhead to its start. A dragged title stops at the minimum gap from its neighbour; pull on further to overlap. Double-click the timecode to type a time to go to (Tab between fields). The scroll bar under the waveform scrolls through the film.
- **Jogging settings** (KPTN.SUB ▸ Settings): mouse jog and wheel jog can each be switched off, step by 1 frame, 10 ms, 5 ms or 1 ms, and have their own sensitivity. The mouse needs the same travel per step however fast you move, and a jerk can't throw an edge far; one wheel click back always undoes one forward. Mouse, wheel and the [ ] keys can be mixed under one hold of Control or Option (wheel for rough, mouse for fine): they move the same edge, so each carries on exactly where the other stopped, and the whole hold is one undo step that plays once when you let go.
- **Several languages on the waveform.** Double-click a slim language lane's tag to open it as a full band (or View ▸ All Languages on the Waveform). Click or drag in any band to work on that language; drag the line between bands to share the height; double-click a band's tag to fold it back.
- **New Project** takes several subtitle files at once (one per language; the language is guessed from the file name or text).
- **Several titles at once.** Shift-click boxes on the waveform, or Shift-drag on empty waveform to draw a selection box; ⌘A (waveform focused) selects every title. Drag any selected box to move the group. Title ▸ Shift Titles… (⌥⌘T) moves the selection, a whole language, or all languages by an offset (seconds or timecode).
- **Videos.** New videos are added in the project view (PROJECT in the top strip, ⇧⌘P). In the editor a video can only be replaced (Replace Video File…, or drop a file), keeping its titles. A missing video shows a banner with Locate…, and a file with the same name next to the project is found automatically.
- **Recovery.** File ▸ Reload Project from File… and Restore from Backup….
- **New Project** can add several languages at once and take a video link.
- **Trackpad swipe** over the selected title's box adjusts its edges (on by default); elsewhere a swipe scrolls.
- Double-clicking a `.kptnsub` file opens it in the packaged app.

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
| While spotting | A timer in the box's top right corner (and on the video) shows the length, coloured by the standard: gold while too short, periwinkle when fine, gold near the maximum, red over it. The card list scrolls to each new title. |
| Live spotting, Tap mode | **↓** ends the current title and starts the next. **↑** ends the current title and leaves a gap. |
| Spotting offsets | A title starts exactly where you press ↓ and ends exactly where you release it. Both can be offset in Settings (⌘,). |
| Split a title | Hold ⌘ over a box (the cursor turns into scissors) and click where it should split, or press ⌘B to split the title under the playhead. A gap of the standard's minimum (2 frames) is left, half on each side. The left title keeps all of the text and the right one starts empty. |

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

Dragging the body of a box moves the whole title, and it plays from half a second before its new start. After adjusting an edge, the whole title plays from 1 s before its start to just after its end. Each replay (jogs/nudges, drag-resizes, drag-moves) can be turned off on its own in the Title menu. A plain scroll wheel, trackball or Shift+scroll only pans the waveform and never changes a title. Jogs and nudges stop at the neighbouring title, keeping a 2-frame gap. Mouse drags stop at the minimum gap from a neighbour; drag about 16 px further and it gives, so titles can overlap; overlapping titles turn lilac and are drawn one slightly higher and one slightly lower.

**Navigation**

| Key | Action |
| --- | --- |
| Shift+Space | Play / pause, from anywhere. While typing, press Shift on its own and hold it a moment first, so a capital followed by a space just types |
| Tab / Shift+Tab | Next / previous title in the focused language (rows where it has no title are skipped). The playhead jumps to it, and editing carries over if you were typing. Shift+Tab works like a player's Back button: with the playhead part way into the title, it first goes back to that title's start. With a group selected, Tab lets go of it and moves past it |
| ← / → | Step one frame back / forward (Shift: one second) |
| ↑ / ↓ while paused | Select the previous / next title and jump to it |
| Return, Space, or just start typing | Edit the selected card's text (cursor at the end; Space types no space), or fill a selected empty slot |
| Return while typing | New line in the title (Esc leaves the text; Tab goes on to the next card) |
| ⌥⌘B | Re-break the selected title's lines |
| ⇧⌥⌘B | Re-break every title in the focused language |
| ⌘L / ⇧⌘L, ⌘1–9 | Focus the next / previous language, or column 1–9 |
| Click a card | Select it, move the playhead to its start, and edit its text with the cursor at the end |
| Esc | Leave text editing (a small "esc" on the card reminds you while you're typing) |
| ⌃⌫ or ⌃⌦ (when not typing) | Delete the selected title (plain ⌫ doesn't) |
| ⌘V / ⌘I on a selected title you aren't typing in | Paste at the end / make the whole title italic (an empty title: what comes next is italic) |
| ⌘F, ⌥⌘F | Find, Find and Replace |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌘; | Next title with a misspelled word |
| ⌘Z / ⇧⌘Z | Undo / redo |
| Scroll / two-finger swipe | Pan the waveform |
| ⌘ + scroll, or pinch | Zoom the waveform |
| Click the ruler | Seek |
| Right-click a box | Play, edit text, delete |
| Double-click a card's or box's number | Play that title |

During playback, the last title the playhead reached stays highlighted, and the card list scrolls to keep it centred. Starting playback leaves text editing.

**Settings (⌘,).** Jog speed (how fast Control/Option + mouse moves an edge), spotting mode, reaction offsets, the trackpad swipe option and the three replay options.

**Line breaks.** With Title ▸ Break Long Lines Automatically (on by default), a title too long for one line is broken when you leave its card, following the Netflix and BBC guides: break after punctuation or before a conjunction or preposition, never after an article, pronoun, auxiliary or preposition, keep names together, and prefer a shorter top line. English and Croatian (also Bosnian and Serbian) have word lists; other languages break at punctuation and for balance. Titles with your own line breaks are left alone; pasted text (⌘V) is always re-broken. Cards keep the on-screen line breaks: a line too wide for the card shrinks instead of wrapping.

**Waveform display.** Boxes show the full text of each title, wrapped to fit. The **Scale** slider makes quiet passages larger. The **dB** toggle shows loudness in decibels, so whispers stay visible next to loud sounds.

**Timing colours.** Periwinkle means OK, pale gold means close to the limit, and red means over the limit, for both reading speed (CPS) and duration. Lilac means overlapping. Amber is only ever the selection. Limits come from the project's standard and each language's overrides.

## Code layout

```
Sources/Titles/
  TitlesApp.swift            app, window, menus
  Model/                     Subtitle, document + undo, SRT/VTT, Project/Track/rows, ProjectStore, AppModel
  Playback/                  PlaybackEngine protocol + AVFoundation engine (libmpv slots in here)
  Audio/                     audio decoding, waveform pyramid, scrub-audio grains
  Input/InputController.swift  modifier jog, nudges, wheel, spotting keys
Sources/CHunspell/           Hunspell 1.7.2 spelling engine, unchanged (MPL 1.1; see its README)
scripts/                     package-app.sh (the .app), fetch-dictionaries.sh (spelling dictionaries)
  Views/                     theme, top strip, home, sheets, card columns, video pane, title bar, waveform
Tests/TitlesTests/           automated tests (run with `swift test`)
```

## Tests

`swift test` runs about 210 checks in under a minute. They cover reading and writing SRT and WebVTT (old Windows encodings included), timecodes at every frame rate, line breaking in English and Croatian, formatting tags, undo, how languages pair up into rows, locked languages, Tab and nudging, splitting, importing files into a project, the project file itself, italics, pasting, Find and Replace, spell checking (with a tiny test dictionary) and drawing a title near its neighbours. A fake player stands in for the video, and nothing is written outside the temporary folder: the tests never touch your projects, backups, recent-projects list or learned words.

Not covered, because they need hands on a mouse: how dragging feels on the waveform (resistance, snapping), jog sensitivity, and anything drawn on screen.

## Known limits

- Only the formats AVFoundation supports will play (see above).
- It runs as a Swift package, so it isn't sandboxed and isn't packaged for the App Store yet.
- Audio is decoded to 16 kHz mono in memory, about 230 MB for a 2-hour film.
- Columns are reordered from the column menu (Move Left / Right), not by dragging.
- Old subtitle files in Hebrew, Arabic, Baltic or Vietnamese Windows encodings aren't recognised (save them as UTF-8 first). Central European, Western, Cyrillic, Greek and Turkish ones are.
- With a standard of three or more lines, a line can come out a character or two over the limit where a better split existed (two-line standards always find the best split).
