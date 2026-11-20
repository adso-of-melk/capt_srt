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
- **Duplicate Language** (the **+** at the end of the column headers, or the Language menu) makes a copy of a language with all its titles, text and timing, in a new column beside it, named "English copy". A copy of the master is linked to it row for row; a copy of another language keeps that language's links, lock and options. Give it its own name or language in Language Options. Two languages with the same code export as `Film.en.srt` and `Film.en-2.srt`, so neither writes over the other.
- Rows line up by link, not by number, so an empty slot keeps later rows aligned. Double-click an empty slot, or select it and start typing, to make a title with that row's timing.
- Column headers have a menu (⋯ or right-click): **Language Options…**, lock or unlock, make master, move left or right, close, delete. **+** reopens a closed column or adds one.
- **Language Options…** changes which language a column is (from the list, or any code and name; spell check, line breaking and the export file name follow, and the project words go along), makes it the master or sets free/locked timing, sets its own reading speed, characters per line and lines, turns spell check on or off for that language, with its project words listed to review or remove, and sets how it exports: UTF-8 or an older code page (Windows-1250 Central European, 1251 Cyrillic, 1252–1257, 874 Thai; characters a code page can't hold become “?” and export says how many), and for right-to-left languages (Arabic, Hebrew, Persian…) right-to-left marks on each line so punctuation lands on the correct side.
- **⌘L / ⇧⌘L** move focus to the next / previous language (wrapping), and **⌘1–⌘9** jump to a column, even while typing. The focused language is the one you edit, in the cards and the waveform.
- The waveform shows the other open languages as slim lanes above it. Click a lane to focus that language. The selected row is outlined in every lane.
- **Text Only (⇧⌘T)** hides picture and waveform, leaving the columns and a slim transport.
- Undo and redo (⌘Z / ⇧⌘Z) work across all languages in order. While paused, the playhead goes to what changed (half a second before a removed title).

## Coming in the next build

- **New Language…** (Language menu, and a column's menu) adds a language with no titles and no timecodes, ready for spotting or drawing titles on the waveform. **New Language from Master…** still copies the master's timecodes.
- **Export in many more formats:** TTML (IMSC 1.1, for Netflix, Amazon and broadcasters), DFXP, iTunes Timed Text (.itt), EBU STL (teletext, binary), Advanced SubStation (.ass) and SubStation (.ssa), YouTube (.sbv), plain text, a dialogue list with timecodes, and Avid DS captions. The Export dialog says what each is for. EBU STL, the dialogue list and Avid count from the project's start timecode.
- **Language Options** gain: a minimum duration of the language's own; how two-line titles are broken (bottom-heavy, balanced or top-heavy); the language's own export format, byte-order mark and line endings (exporting all languages, each keeps its format); and, for Serbian (and Bosnian, Montenegrin), **Convert the titles to Latin / Cyrillic letters** (one ⌘Z; the language code follows, sr-Cyrl ↔ sr-Latn).
- **Match TC to Neighbour.** Shift-click one or more titles, right-click ▸ Match TC to Neighbour (or the Title menu), then click the title to match, in any language: a card, a waveform box or a slim lane. One title takes its start and end; several move together so the first starts with it, keeping their lengths and gaps. Esc (or a click on empty waveform) cancels; one ⌘Z undoes it. With overlapping titles off, one title is shortened to keep clear of its neighbours, and a group goes to the nearest free place. **Match TC to Linked Titles** gives each picked title the times of the master title beside it, with no click.
- **Smooth spotting.** Spotting no longer drops the waveform back to frame-by-frame drawing: the title being spotted grows on the pre-drawn strip by the film's clock, with its number and running time, and lands in the strip when the key comes up.
- **Speech on the waveform.** Where people speak is shaded behind the waveform, with a line along the foot of each band (worked out once from the video's sound, after the waveform). The **Speech** button beside dB turns it off.
- **Re-split to Fit** (QC menu, and the issue tag of a title too fast, too long or too short): a title with more text than its lines hold is split at the best place (a sentence's end, a comma, a new speaker), the time shared by the length of the text; a title too fast to read shares its words and time with a neighbour less than a second away, moving the time between them as little as it can; a title shorter than the minimum joins a neighbour when the two fit as one. One ⌘Z.

- **Join Titles (⌘J).** Shift-click cards (or waveform boxes) to pick neighbouring titles, then ⌘J, Title ▸ Join Titles, or right-click ▸ Join. They become one title from the first start to the last end, with the text re-broken by the rules; one ⌘Z undoes it. A language locked to the master joins its matching titles too.
- **QC mode (⌘K, QC menu).** The window goes to "yellow alert": a QC bar under the top strip with a slowly pulsing light, a thin yellow frame round the panes, warmer panels and waveform. Titles with an issue get a yellow outline and a tag naming the issue on the card's lower edge, and a yellow bar over their waveform box; the rest step back. The bar counts each kind of issue in the focused language: spelling, reading speed (CPS), characters per line (CPL), too many lines, duration, overlaps, gaps under the minimum, empty titles. Click a kind to look for it or skip it.
- **Tab / Shift-Tab in QC mode go from one title with an issue to the next** (wrapping round), with the playhead at its start and the issue named at the bottom of the window. Typing in a card carries over, as with plain Tab.
- **Automatic fixes** (QC menu, or FIX in the QC bar; one ⌘Z each): **Extend to Fit Reading Speed** (⌥⌘E for the selected titles, or all) lengthens titles that read too fast or are shorter than the minimum duration, into the free room after them first and then before, keeping the minimum gap and never past the maximum duration. **Widen Gaps to the Minimum** (selected or all) moves titles that are too close apart: the earlier title's end comes back, and only when that title is already at the minimum duration does the next one's start move. **Close Short Gaps** closes gaps under half a second down to the minimum by moving the earlier title's end on (not past the maximum duration).

- **Reading speed over by any amount** counts in QC (17.02 CPS, shown as 17.0, is over), and titles close to the limit (amber on the card) are their own kind, **Near CPS**. Every kind is looked for at first; click a kind in the QC bar to skip it, **ALL** to look for every kind again.
- **Drag a column's header bar** left or right to move the column (as Move Column Left / Right).
- **Two languages open as bands on the waveform stay open** when you click from one to the other; double-click a band's tag to fold it.
- **Deleting a title** selects the next one on the waveform too: the playhead goes to its start.
- **Italics stick:** deleting italic text and typing again keeps the italics, even when the card resizes its text.
- **Croatian spelling:** words the dictionary was missing (faliti, šutjeti, trpjeti, zavidjeti, buraz, bend, pizza, mejl, okej…) are added with all their forms. More can go in `dictionaries/hr.extra.dic` (see `dictionaries/README.md`); the same works for any Hunspell language.
- **"Pre" and "naj" words** (Croatian, Bosnian, Serbian, either alphabet): a word the dictionary doesn't know is right when it is *pre* or *naj* in front of a word it does know (preplaha, prebrzo, najplahiji).
- **Issues show all the time, not just in QC mode,** so titles can be checked as they're made: a yellow tag on the card's lower edge names what's wrong, and a yellow bar sits over the waveform box. Click the tag for the details and the fixes that apply to that title (Extend to Fit Reading Speed, Widen Gaps to the Minimum, Re-break Lines; one ⌘Z each). The title you're typing in shows no tag until you leave it, so tags don't flash on and off mid-sentence. **QC ▸ Check For** picks which kinds of issue are shown (as the chips in the QC bar do). QC mode itself adds the yellow-alert colours, the counts bar, dims the titles with nothing to fix, and makes Tab / Shift-Tab skim from issue to issue.
- **Keep Minimum Gap (Title menu and Settings, on at first).** No gap between titles goes under the project's minimum. Dragging, nudging and jogging already stop a title there; now a title that sits too close to its neighbour (in an imported file, or after the minimum was raised) gets that gap fixed as soon as you move it, in the same ⌘Z step: the earlier title's end comes back, so starts stay on their words. After an import (or a larger minimum in Project Settings) a note says how many gaps are short; QC ▸ Widen All Gaps to the Minimum fixes them all at once. Off: titles still stop at the minimum gap, but pull a little further (or nudge once more) and they go closer, down to touching (and over the neighbour only with Enable Overlapping Titles).
- **QC cards keep their height:** the issue is named on a small yellow tag hanging on the card's lower edge (hover it for the details) instead of on a row of its own, so the list is laid out the same in and out of QC mode and scrolls evenly. The QC bar's counts are worked out only when something changes.
- **Drop a mess of videos and subtitle files (or whole folders) onto the window** and they're matched up: on the home screen into a new project, in the project view into the open one. A dialog shows each video with its files and why each was put there: **EPISODE** (S01E03, 1x03, Ep 3, Epizoda 3, a lone number; different episode numbers never match), **NAME** (the name without its language tag and extras like final, v2, SDH, 1080p, x264, a year), **FOLDER** (the only video in the file's folder), **TIMING** (translations of one cut share most of their start times, so a badly named file goes with the files timed like it), **LENGTH** (a guess, in amber: the titles fit that video's length; titles that run past a video's end never go to it). Change any file's language, move it to another video with its menu or by dragging (the files timed like it can come along), or leave it out; anything unmatched waits at the bottom. The master language is suggested (the usual one if every video has it, otherwise the one most videos have), and so is the project's name. Subtitle files dropped without videos become one video per cut, to be located later.
- **The title pane's divider always moves**, however many languages are open (more columns than fit scroll sideways), and it's one 8-point grab strip with the resize cursor along all of it. Double-click it to put the pane back to its usual width.
- **Issue tags in every language**, not just the focused one: the other languages' tags and waveform bars are in the quiet blue of their cards. QC mode's outline and dimming stay with the focused language.
- **Drop subtitle files on a video's card in the project view** and they go straight into that video, one language each (the card lights up while you hold them over it). Videos can be added on their own first and filled one by one this way.
- **CPS and CPL in the other languages' columns** are in the same quiet blue as their cards, with only a red or gold rim when they're over, so they nudge without shouting. The focused language keeps the full colours.
- **Languages on the waveform, one rule each:** a click on a language's code moves you to that language and nothing else (it doesn't open, close or jump). A double-click opens or closes it. Drag a code up or down to move the language, its column in the title pane moving with it; drag a slim lane's code up among the open languages to open it there, or an open language's code down among the slim lanes to close it. Each open language gets room for two lines; opening one more than fits closes the lowest open one (never the one you're in). The language you're in can be closed: its code in the slim lanes is amber and its selected title is outlined. One language always stays open.
- **Smarter matching when names don't help.** Files are timed alike when most of their titles start within half a second of each other, even with one moved against the other (up to 10 s, or whole hours as in broadcast files starting at 10:00:00) or timed for another frame rate (25 against 23.976 or 24 fps). The TIMING chip says how alike (TIMING 92%), and turns amber when the file is offset or at another frame rate; hover for the details. When files are still unplaced (or placed by length alone), the videos are listened to once ("Listening to video 2 of 4…"): each set of files goes to the video whose speech its titles follow, when that's clearly the one (**SPEECH**). Length is the last resort.
- **Languages are told apart by their own letters.** A file's language is read from words taken all through it (not just the start), and languages that look alike are told apart by the letters only they use: Serbian (ђ ћ ј љ њ џ) and Macedonian (ѓ ќ ѕ) from Russian, Bulgarian and Kazakh; Ukrainian, Belarusian, Kazakh and Mongolian by theirs; Persian (پ چ ژ گ and its own ی ک) from Arabic; Urdu (ٹ ڈ ڑ ں ے), Pashto and Kurdish (Sorani) by theirs. A code the app has no name for is named in English (Kazakh, not "kk (kk)").
- **Older Arabic, Persian, Hebrew and Thai files** (Windows code pages 1256, 1255, 874) open with the right letters, as Cyrillic, Greek and Central European ones already did.
- **Behind the scenes: the core is its own module.** Titles, projects, the subtitle formats, QC's rules, line breaking and the timing rules now live in TitlesCore, apart from the Mac app's windows (see Code layout). Nothing changes in the app.
- **A project with several videos opens at the project view**, with the video worked on last outlined: Return (or a double-click) goes back into it. A project with one video opens straight into the editor, as before.
- **Sort the project's videos** (Sort menu in the project view): by name (numbers in order, so episode 2 comes before episode 10), by date added (newest first) or by last edited (latest first). Each project remembers its choice; the video menu in the top strip follows it. Videos from before this build have no dates, so they keep the project's order after the dated ones.
- **The language chips on a video's card show just the codes**; hover one for the language's name and how many titles it has.
- **The line between the picture and the waveform always moves too**, like the title pane's divider: one 8-point grab strip with the up-down resize cursor along all of it, which nothing in the picture or the waveform can take the mouse from. The picture keeps at least 240 points and the waveform (with its control bar) 170; double-click the line to put the waveform back to its usual height.
- **Sideways, the title pane goes a whole language at a time**, so a language always ends up at the pane's left edge, never half in view. A mouse wheel moves one language a notch (Shift and the wheel, or a sideways wheel), in the direction it turns; a trackpad swipe moves one once it has gone a little way, and one more for each longer stretch. Dragging the bottom scroll bar stops on whole languages too, and so does bringing another language into view with ⌘L. Up-down scrolling is as before.
- **The title pane's scroll bars work like the Mac's own:** a capsule as long as the share of the list (or of the languages) in view, on a faint track. Grab the capsule and drag it: it stays under the pointer where you grabbed it, and the cards follow exactly. Click the track and the capsule jumps there. The up-down capsule follows the list exactly as it scrolls.
- **Waveform boxes stop at the waveform's edge** again, instead of being drawn over the title pane when scrolled past it.
- **The cards glide with the film.** While playing, the list eases to each title the playhead reaches over about half the time until the next one (0.3 to 0.9 s) instead of jumping there; a title you pick by hand (a click, Tab) is still scrolled to straight away.
- **No stutter in the picture as the cards move.** Each time the playhead reached a title, the whole window was redrawn and every card on screen worked out its text again; now only the two cards that change are redrawn, and the cards remember their text sizes.
- **Scroll bars of our own on the title pane's edges**, always in the same place however far the languages are scrolled sideways. The up-down bar is always there, showing where you are in the film; under the pointer it widens and brightens, and it lights up while the cards scroll (wheel, Tab, following the playhead), fading back after a second. Click or drag anywhere on it to go there. The sideways bar along the bottom appears when the languages don't all fit.
- **Card headers stay on one line.** In a narrow column the timecode and chips get a little smaller first, then the CPS chip shows just the number (hover for the full reading speed), and only then does the timecode step aside. Every card's header is the same height.
- **The language you're working in stands out.** With more than one language open, the others step back: duller (their blues toward slate) and darker. The focused language keeps its full colours and gets an amber rail under its bar.
- **The title pane sizes itself to the languages**, both ways: each time a language opens or closes, every open language gets its full width as long as the pane stays within 40 % of the window; past that the columns narrow equally down to their narrowest, and past that whole columns fill the pane and the rest are scrolled to. A width dragged by hand holds until the next language opens or closes; double-click the divider to go back to automatic.
- **Dragging the up-down scroll capsule is smooth.** While it's held, the cards come in light (no issue tags or spelling underlines) so the list keeps up with the pointer; they fill in as soon as it's let go. Cards also remember their checked text and issues, so they no longer work them out again each time they're drawn.
- **Columns swap as you drag a language's header.** Once the header is half way over its neighbour, the two change places there and then (the cards slide across, and a Force Touch trackpad gives a tick), with the header still under the pointer; let go wherever you like.
- **Broken formatting tags are found and repaired.** A new QC kind, **TAGS**, marks titles with an italic, bold, underline or strike tag left open, closed twice, crossed (<i><b>…</i></b>), empty, or typed with a space or a missing bracket (< i >, <i Hello). Its fix is **Repair Formatting Tags** (QC ▸ Repair Formatting Tags in All Titles does the whole language). Export always writes repaired tags, and says how many titles it repaired.
- **Blank lines** (an empty line, or one with only spaces, before, between or after the text) are a QC kind of their own, **BLANK LINE**, with the fix **Remove Blank Lines** (or QC ▸ Remove Blank Lines in All Titles). Export already closed them up.
- **Words partly in italics** (Hel*lo*) are a QC kind, **PART ITALIC**. Whole words in italics don't count, nor do punctuation marks outside the italics. Its fixes: **Italicize Whole Words** or **Remove Italics From Those Words**.
- **Drag words from one card into another.** Select words in the card you're typing in and drag them onto another title's card: they go to the start of a later title (or the end of an earlier one), leave the card they came from, and both titles' lines are broken again by the rules (with automatic line breaks on). Italics come along. Hold Option to copy instead; into another language they're always copied. One ⌘Z undoes it. Handy after splitting a title whose lines are too long: drag the end of the first card into the new, empty one.
- **Opening a language on the waveform makes room for it.** Double-click a slim lane's code (or drag it up among the open languages) and the waveform pane grows, smoothly, until every open language has comfortable room, as far as the picture can give. A pane already tall enough stays as it is.
- **Open languages never get squeezed.** The waveform pane can't be dragged (or a window shrunk) so short that an open language's boxes lose their two lines of text; the line between two languages stops there too. When even that won't fit, opening a language closes the lowest open one, as before.
- **Other languages step back on the waveform too**, as their columns do in the title pane: their boxes in the quiet blue of their cards, a rim in gold or red when a title is near or over a limit, less colour and a little darker all round, and their waveform and slim lanes with them.
- **Warnings in other languages read clearly:** the CPS and CPL chips in a column you're not in keep a little more of their colour than the rest of the card, and over the limit (red) gets a stronger rim and a red wash, so it never draws less notice than near it (gold).
- **The waveform glides while playing.** It now moves on every frame the screen shows, at the player's own time, instead of on the clock's ticks (which don't line up with the screen's frames, so the boxes moved in uneven steps). The audio's outline is worked out once a frame for all the languages.
- **The waveform moves with the picture, frame for frame.** While playing, the waveform is no longer redrawn on every frame: it's drawn ahead in strips, and the Mac's graphics system slides them along by the video's own clock, so the boxes glide in step with the picture on every frame the screen shows, however busy the rest of the app is (a new title reached, the cards moving). Only what changes is redrawn, a little at a time: the title that's selected as the playhead reaches it, a title typed in or moved. The language codes, the scroll bar and the playhead stay put on top. A click, the wheel or a pinch on the waveform hands it back to its usual drawing for a moment, so what's under the pointer is exactly what's drawn; the strip takes over again when the hand is off.
- **The title cards flow with the film.** While playing, the cards move on every frame the screen shows, by the video's own clock, instead of gliding from title to title: each title's card reaches the middle of the pane just as it starts, and in between the list moves on smoothly, quicker through short titles and slower through long ones and pauses. Scroll the cards by hand and they stay where you put them until the next title is reached, then ease back. Typing, spotting and previews hold them still, as before. **Settings ▸ Title cards flow with the film while playing** turns it off (the cards then glide to each title as before).

## New in 0.47

- **Overlapping titles are off by default.** A dragged title (whole box, an edge, a group, or a title being drawn) stops at the minimum gap from the next title and never goes over it. Spotting, a new title in an empty slot and Shift Titles keep clear of other titles too. Titles that already overlap (in an imported file) stay as they are, and can be pulled apart. **Title ▸ Enable Overlapping Titles** (also in Settings) lets a title go over its neighbour when pulled on.
- **Stronger resistance, and it comes back.** With overlaps enabled, a title has to be pulled 40 px past the stopping point (was 16) before it gives. Every time two titles stop overlapping during a drag, the resistance is back at full strength, and after passing through one title the next one holds it in turn. A fast drag can't jump over a title.

## New in 0.45

- **Duplicate Language.** Under **+** (and in the Language menu): a copy of a language with all its titles, in a new column beside it.
- **Mouse jog really does work outside the window now** (0.42's version didn't). Hold Control or Option with the pointer anywhere (the desktop, another window, another display) and move the mouse: after a few points of travel the jog starts. The hidden pointer is brought inside the window for the hold and put back where it was when you let go. KPTN.SUB watches the pointer's position itself while the key is held, so this no longer depends on how macOS reports movement out there.
- **Two languages with the same code export to two files** (`Film.en.srt`, `Film.en-2.srt`) instead of one writing over the other.
- **WebVTT is always UTF-8**; a language's older code page applies to SRT only.
- **Smoother waveform with many titles**: each box's formatted text is worked out once, not on every redraw.

## New in 0.42

- **A small "esc" while you type.** The card with the text cursor shows a little "esc" key on the lower edge of its text box. Esc takes the cursor out; then ⌘I makes the whole title italic again, ⌘V pastes at its end, and Tab, ⌘I runs through titles quickly.
- **Language Options…** in each language's menu: change the language (or its code and name), master and timing, its own reading speed, characters per line and lines, spell check with its project words, and export text encoding (UTF-8 or an older Windows code page) plus right-to-left marks for Arabic, Hebrew and Persian.
- **Mouse jog works outside the window.** Holding Control or Option and moving the mouse keeps jogging even with the pointer over another window or the desktop, as long as KPTN.SUB is the active app.
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
- **Drawing a title stops at the minimum gap** from its neighbours, like stretching one does; with overlapping titles enabled, pull on about 40 px to overlap. Starting a drag inside the gap starts it at the gap's edge.
- **Selection and warning colours no longer clash.** A selected box keeps its timing colour (0.30: inside amber brackets); amber now means only "selected". Near the limit is pale gold everywhere (cards, chips, waveform, spotting timer).

## Since the build of 2026-11-09

- **Rows by time.** Card rows are built from timing alone: titles from different languages that start within 0.25 s, or overlap for half their length, share a row. Moving a title never reorders another language. Each language is numbered on its own.
- **Formatting.** `<i>`, `<b>` and `<u>` show as italic, bold and underline in cards and on the video; tags don't count towards CPS or characters per line. ⌘I wraps the selection in `<i>…</i>` while typing.
- **Typing.** Shift+Space plays unless you typed a letter while holding Shift (a capital then a space). Tab puts the cursor at the end of the next card. Hover a column's coloured cap to close it.
- **Formatting.** Cards show and edit italics, bold and underline as they look (⌘I toggles italic); the file keeps the tags.
- **Line breaks while typing.** When a line runs past the limit, the title is re-broken by the rules as you type; leaving the card evens the lines out, unless you broke them yourself with Return. Title ▸ Re-break All Lines (⇧⌥⌘B) does every title in the focused language.
- **Waveform.** Clicking a title moves the playhead to its start. A dragged title stops at the minimum gap from its neighbour; with overlapping titles enabled (Title menu), pull on further to overlap. Double-click the timecode to type a time to go to (Tab between fields). The scroll bar under the waveform scrolls through the film.
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
| Subtitles out | **File ▸ Export… (⇧⌘E)**: this language or all languages, this video or all videos, named by the project pattern (default `{video}.{lang}`). SubRip (.srt), WebVTT, TTML (IMSC 1.1), DFXP, iTunes Timed Text (.itt), EBU STL, Advanced SubStation (.ass), SubStation (.ssa), YouTube (.sbv), plain text, a dialogue list with timecodes, and Avid DS captions. Rows are renumbered on export. UTF-8, with optional BOM and CRLF (per language in Language Options, with the language's own format and an older code page where the format allows one). EBU STL, the dialogue list and Avid count from the project's start timecode. |

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
| Jog: hold the key and move the mouse. The cursor hides, and the video and audio scrub as you move, even with the pointer outside the KPTN.SUB window. Release to lock and preview. | **Control** | **Option** |
| Coarse jog | Control + Shift | Option + Shift |
| Cancel a jog (while still holding) | Esc | Esc |
| Nudge 1 frame (Shift: 10) | Control + [ / ] | Option + [ / ] |
| Wheel or two-finger swipe: 1 frame per notch (Shift: 10) | Control + wheel | Option + wheel |
| Two-finger trackpad swipe over a box, no key (off by default; turn on under Title ▸ Trackpad Swipe Over a Title Adjusts Its Edges) | left half of the box | right half of the box |
| Mouse drag | box's left edge | box's right edge |

Dragging the body of a box moves the whole title, and it plays from half a second before its new start. After adjusting an edge, the whole title plays from 1 s before its start to just after its end. Each replay (jogs/nudges, drag-resizes, drag-moves) can be turned off on its own in the Title menu. A plain scroll wheel, trackball or Shift+scroll only pans the waveform and never changes a title. Jogs and nudges stop at the neighbouring title, keeping a 2-frame gap. Mouse drags stop at the minimum gap from a neighbour. With Title ▸ Enable Overlapping Titles on, drag about 40 px further and it gives, so titles can overlap, and it holds again each time they come apart; overlapping titles turn lilac and are drawn one slightly higher and one slightly lower.

**Navigation**

| Key | Action |
| --- | --- |
| Shift+Space | Play / pause, from anywhere. While typing, press Shift on its own and hold it a moment first, so a capital followed by a space just types |
| Tab / Shift+Tab | Next / previous title in the focused language (rows where it has no title are skipped). The playhead jumps to it, and editing carries over if you were typing. Shift+Tab works like a player's Back button: with the playhead part way into the title, it first goes back to that title's start. With a group selected, Tab lets go of it and moves past it |
| Tab / Shift+Tab in QC mode | Next / previous title with an issue (of the kinds ticked in the QC bar) |
| ⌘K | QC mode on / off |
| ⌥⌘E | Extend the selected titles to fit the reading speed |
| ⌘J | Join the picked titles (Shift-click a range, ⌘-click one by one) |
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
| Right-click a box or card | Play, edit text, delete, join the picked titles |
| Double-click a card's or box's number | Play that title |

During playback, the last title the playhead reached stays highlighted, and the card list scrolls to keep it centred. Starting playback leaves text editing.

**Settings (⌘,).** Jog speed (how fast Control/Option + mouse moves an edge), spotting mode, reaction offsets, the trackpad swipe option and the three replay options.

**Line breaks.** With Title ▸ Break Long Lines Automatically (on by default), a title too long for one line is broken when you leave its card, following the Netflix and BBC guides: break after punctuation or before a conjunction or preposition, never after an article, pronoun, auxiliary or preposition, keep names together, and prefer a shorter top line. English and Croatian (also Bosnian and Serbian) have word lists; other languages break at punctuation and for balance. Titles with your own line breaks are left alone; pasted text (⌘V) is always re-broken. Cards keep the on-screen line breaks: a line too wide for the card shrinks instead of wrapping.

**Waveform display.** Boxes show the full text of each title, wrapped to fit. The **Scale** slider makes quiet passages larger. The **dB** toggle shows loudness in decibels, so whispers stay visible next to loud sounds.

**Timing colours.** Periwinkle means OK, pale gold means close to the limit, and red means over the limit, for both reading speed (CPS) and duration. Lilac means overlapping. Amber is only ever the selection. Limits come from the project's standard and each language's overrides.

## Code layout

The app is two modules. **TitlesCore** is everything about titles that isn't a window: it uses only Foundation (plus Apple's language recogniser for guessing languages), so a later iOS app, or a port, can share it. **Titles** is the Mac app around it.

```
Sources/TitlesCore/          the core: no windows, no AppKit
  Subtitle.swift             a title, timing rules (CPS, duration, gap), timing standards
  SubtitleDocument.swift     one language's titles + undo
  Project.swift              Project / video / language, project settings, card rows
  ProjectStore.swift         reading and writing .kptnsub projects, backups
  SubtitleFormats.swift      SRT and WebVTT in and out, timecodes, text encodings
  Markup.swift               italic and other tags
  LineBreaker.swift          line breaking rules
  QC.swift                   what QC finds, in words, and its timing fixes
  DragResistance.swift       where a dragged title stops near its neighbours
  LanguageGuess.swift, FileMatcher.swift, ImportPlan.swift   matching dropped files to videos
  ExportFormat.swift         the export formats, what each is for
  ExportWriters.swift        TTML, DFXP, iTT, SubStation, YouTube, text, dialogue list, Avid
  EBUSTL.swift               EBU STL (binary, teletext)
  SerbianScript.swift        Serbian Cyrillic ↔ Latin
Sources/Titles/              the Mac app
  TitlesApp.swift            app, window, menus
  Model/                     AppModel (every editing action), import, QC commands, spelling, Find
  Playback/                  PlaybackEngine protocol + AVFoundation engine (libmpv slots in here)
  Audio/                     audio decoding, waveform pyramid, scrub-audio grains, speech levels
  Input/InputController.swift  modifier jog, nudges, wheel, spotting keys
  Views/                     theme, top strip, home, sheets, card columns, video pane, title bar, waveform
Sources/CHunspell/           Hunspell 1.7.2 spelling engine, unchanged (MPL 1.1; see its README)
scripts/                     package-app.sh (the .app), fetch-dictionaries.sh (spelling dictionaries)
Tests/TitlesTests/           automated tests (run with `swift test`)
```

For now the app reaches the core with `@testable import TitlesCore` (the core is built with `-enable-testing`), so the core's code needs no `public` marks yet. When a second app shares it, the parts it uses get `public` (or `package`) and the testable import goes.

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
