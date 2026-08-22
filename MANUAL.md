# C64 IDE — User Manual

A native macOS development environment for the Commodore 64 and its 8-bit
relatives. This manual covers day-to-day use: setting the IDE up, writing BASIC
and 6502 assembly, building, running on emulators and real hardware, debugging,
and the built-in asset editors.

---

## Table of contents

1. [Getting started](#1-getting-started)
2. [The main window](#2-the-main-window)
3. [Projects](#3-projects)
4. [Editing code](#4-editing-code)
5. [BASIC dialects and plugins](#5-basic-dialects-and-plugins)
6. [Building and running](#6-building-and-running)
7. [Debugging](#7-debugging)
8. [Real hardware: Ultimate 64 and MEGA65](#8-real-hardware-ultimate-64-and-mega65)
9. [Graphics, character and sound editors](#9-graphics-character-and-sound-editors)
10. [Disk and tape images](#10-disk-and-tape-images)
11. [Reference and utility tools](#11-reference-and-utility-tools)
12. [The AI assistant](#12-the-ai-assistant)
13. [Preferences and appearance](#13-preferences-and-appearance)
14. [Keyboard shortcut reference](#14-keyboard-shortcut-reference)
15. [Where the IDE keeps its files](#15-where-the-ide-keeps-its-files)
16. [Troubleshooting](#16-troubleshooting)

---

## 1. Getting started

### What you need

| Requirement                            | Why                                                                                                                                   |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| macOS                                  | The app is built with Cocoa, AppKit and SwiftUI.                                                                                      |
| `cc65` toolchain (`ca65`, `ld65`)      | Required for **all** assembly builds. `brew install cc65`.                                                                            |
| VirtualC64 (built in)                  | Embedded C64 emulator. No binary needed, but it wants real C64 ROMs.                                                                  |
| VICE (`x64sc`, `x128`, `xpet`, `xvic`) | Optional external emulators. `x128` is used for C128/BASIC 7.0 targets, `xpet` for PET/BASIC 4.0, `xvic` for VIC-20 (Super Expander). |
| xemu (`xmega65`)                       | Optional. Required to run MEGA65 / BASIC 65 programs.                                                                                 |
| Ultimate 64 / MEGA65 hardware          | Optional. Run over the network instead of an emulator.                                                                                |

BASIC programs are tokenized directly by the IDE and do **not** require `cc65`.

### First run

1. Open **C64 IDE → Preferences…** (`⌘,`).
2. Click **Auto-Detect Paths**. This searches Homebrew locations
   (`/opt/homebrew/bin`, `/usr/local/bin`), `~/.local/bin` and
   `/Applications/VICE/…` for `ca65`, `ld65`, `x64sc`, `x128`, `xpet`, `xvic`
   and `xmega65`, and fills in whatever it finds.
3. Fill in anything it missed with **Browse…**. Warnings appear in yellow
   underneath the fields and re-check themselves as you type.
4. Under **C64 Emulator**, choose whether C64 targets run in **VirtualC64
   (embedded)** or **VICE x64sc (external)**.
5. Under **C64 ROMs**, point KERNAL / BASIC / Character ROM at your own dumps of
   the original Commodore ROMs. These are required for accurate VirtualC64
   emulation; leaving them blank falls back to the built-in MEGA65 OpenROMs,
   which are less accurate. VICE has its own ROMs and can ignore these.
6. Click **Save**.

Tool paths are stored globally (per machine). Build _options_ — debug info,
listing files, auto-run and so on — are saved into the active project when one
is open.

On launch with no project, the IDE opens an example BASIC file. Turn this off
with **Show example file on launch** in Preferences.

---

## 2. The main window

The window is split into three regions plus a toolbar.

```
┌──────────────────────────── toolbar ─────────────────────────────┐
│ Run  Stop        U64  MEGA65        Git ● Theme Reference Console │
├──────────────────────────────────┬───────────────────────────────┤
│  Tab bar: game.bas  sprite.s  …  │                               │
│                                  │      Reference panel          │
│  Editor                          │   Commands · Memory · ROM     │
│  (line-number gutter with        │   Colors · PETSCII ·          │
│   breakpoint dots)               │   Monitor · Variables         │
│                                  │                               │
├──────────────────────────────────┴───────────────────────────────┤
│  Console:  Build │ Messages │ Search │ AI                        │
└──────────────────────────────────────────────────────────────────┘
```

### Toolbar

| Item             | Action                                                                                                    |
| ---------------- | --------------------------------------------------------------------------------------------------------- |
| **Run**          | Build and run the active file (`⌘R`). The icon and tooltip change when the active dialect routes to xemu. |
| **Stop**         | Stop the running emulator (`⌘.`).                                                                         |
| **U64 / MEGA65** | Send the build to real hardware (shown when configured).                                                  |
| **Git**          | Repository status dot. Click for commit / push / pull.                                                    |
| **Theme**        | Toggle light and dark mode.                                                                               |
| **Reference**    | Show/hide the right-hand reference panel (`⌥⌘R`).                                                         |
| **Console**      | Show/hide the bottom panel (`⇧⌘Y`).                                                                       |

Right-click the toolbar to customize which items appear.

### Editor tabs

Each open file gets a tab. A `•` after the name means unsaved changes. Close the
active tab with `⌘W`. New files open in a new tab (`⌘N` for BASIC, `⇧⌘N` for
assembly).

### Reference panel (right)

Seven tabs, searchable where relevant, that follow what you are typing:

- **Commands** — keyword reference for the BASIC you are writing, plus a 6502
  opcode reference; the segmented control at the top switches between them, and
  the panel picks the right one for the file you are editing.
  The BASIC list starts from BASIC V2 and picks up the active dialect's
  keywords when you switch dialect, each with its syntax, parameters, example
  and token bytes. Selecting MEGA65 BASIC 65, for instance, takes the list from
  76 entries to 228.
  The assembly list covers all 56 documented 6502 instructions and the 19
  undocumented ("illegal") mnemonics the 6510 also executes — every one of the
  256 opcode bytes is accounted for. Each entry gives a description, the flags
  it affects, a table of every encoding (opcode byte, length and cycle count,
  including the conditional page-cross and branch-taken penalties), a worked
  example and notes. The undocumented entries flag the genuinely unstable
  instructions, and record where ca65 spells a mnemonic differently from the
  Disassembler window — `ISC` for `ISB`, `ANE` for `XAA`, `AXS` for `SBX`.
  Searching finds either spelling. ca65 assembles these only after
  `.setcpu "6502X"`.
- **Memory** — annotated C64 memory map (VIC, SID, CIA registers and so on).
- **ROM** — KERNAL / BASIC ROM routine list with entry points.
- **Colors** — the 16-colour C64 palette with indices.
- **PETSCII** — character codes and screen codes.
- **Monitor** — a cheat sheet for the monitor of the currently attached run
  target (VICE text monitor or VirtualC64 RetroShell).
- **Variables** — variables found in the current BASIC source, updated as you
  type.

### Console panel (bottom)

- **Build** — compiler and linker output, errors and warnings, disk bundling
  results. Click a diagnostic to jump to the offending line.
- **Messages** — general IDE messages.
- **Search** — find and replace across **Current Tab** or **All Tabs**, with a
  case-sensitive toggle, `↩` / `⇧↩` to step through matches, and Replace /
  Replace All.
- **AI** — the assistant chat (see [section 12](#12-the-ai-assistant)).

---

## 3. Projects

A project is a `.c64proj` JSON file that records the project name, main file,
active BASIC dialect, project-scoped build options, disk configuration, and your
editor session (open files, selected tab, breakpoints). Because session state
lives in the project file, it survives a `git clone` onto another machine.

### Creating and opening

| Action                      | Where                                       |
| --------------------------- | ------------------------------------------- |
| New empty project           | **File → New → New Project…** (`⌥⌘N`)       |
| New project from a template | **File → New → New Project from Template…** |
| Open                        | **File → Open Project…** (`⇧⌘O`)            |
| Recently used               | **File → Recent Projects**                  |
| Save                        | **File → Save Project** (`⌥⌘S`)             |
| Close                       | **File → Close Project**                    |

The last project reopens automatically at launch unless you opened something
else first.

Two templates ship with the IDE:

- **Simple Game Starter (Assembly)** — 6502 skeleton with a BASIC SYS stub, CIA
  timer frame sync, joystick reading on port 2, a placeholder sprite, CHROUT
  score display, title screen and game-over screen.
- **Simple Game Starter (BASIC)** — BASIC V2 skeleton with title screen,
  joystick reading, score and lives, a main loop and a game-over screen.

### Project settings

**File → Project Settings…** (`⇧⌘,`) opens a sheet with two tabs:

**Disks** — define the disk images the project builds and mounts. Per disk:

- Label and filename (e.g. `build/game.d81`)
- Format: **D81** (1581, 800 KB) or **D64** (1541, 170 KB)
- CBM disk name and two-character disk ID
- Drive number (8, 9, …) and which disk is the **primary (boot)** disk
- Boot program name (what `LOAD` looks for)
- Whether the emulator may write to the image

**Build** — where the compiled PRG lands: the CBM filename to write (max 16
ASCII characters) and which configured disk to write it to. Choosing **None
(PRG inject mode)** skips disk bundling and injects the PRG directly into the
emulator. When a target disk is set, every build bundles the PRG onto that image
and mounts it.

At the bottom of the sheet, **Override global C64 emulator for this project**
lets a single project pin itself to VirtualC64 or VICE x64sc regardless of the
global preference.

### Git

If the project folder is inside a Git repository, the toolbar shows a status
dot. Clicking it offers **Commit** (with a message sheet), **Push** and
**Pull**. The dot colour reflects clean / dirty / no-repo state.

---

## 4. Editing code

### Common to all files

- Syntax highlighting for BASIC and 6502 assembly.
- Line-number gutter; click the left edge of the gutter to toggle a breakpoint.
- Inline tooltips for keywords and addresses when you hover.
- Find panel (`⌘F`), plus the richer Search tab in the console panel.
- External changes are detected: if a file changes on disk underneath you, the
  IDE offers to reload it.
- Non-BASIC files keep the previous line's indentation when you press Return.

### BASIC-specific behaviour

**Auto line numbering.** Press Return on a numbered line and the IDE inserts the
next line number for you, choosing a number that fits in the gap before the
following line. If there is no room (you are editing line 790 and 791 already
exists) it simply inserts a plain newline.

**Auto-arrange.** If you commit a line whose number puts it out of order, the
IDE moves it into its correct position automatically. If the number duplicates
an existing line, you are asked whether to replace that line or renumber the new
one.

**Shortcut expansion.** Commodore's keyword abbreviations expand to full
keywords when you commit a line — `?` becomes `PRINT`, `pO` becomes `POKE`, and
so on, using the universal V2 abbreviation table plus any abbreviations the
active dialect plugin defines. Expansion is skipped inside string literals, in
`REM` comments and in `DATA` statements, so `PRINT "WHAT?"` is left alone. The
same expansion runs when a file is loaded and when text is pasted, so the buffer
always contains canonical full keywords.

**Renumbering.** **Edit → Renumber BASIC Lines…** (`⇧⌘L`) renumbers the whole
program, or only the selection if there is one. Enter a start (1–63999) and a
step; all `GOTO`, `GOSUB`, `THEN` and similar references are rewritten to match.
If a renumber would break something, the IDE reports why instead of doing it.

**Variable scanning.** The Variables tab of the reference panel keeps an updated
list of the variables in the current program, respecting the active dialect's
naming rules (for example two-significant-character names).

### Fonts and theme

**View → Editor Font** offers **Font Settings…** (family picker plus a 9–36 pt
size slider), **Increase Size** (`⌘+`), **Decrease Size** (`⌘-`) and **Reset to
Default** (`⌘0`). These affect the source editor only, not tool windows.

The toolbar's sun/moon button switches the whole IDE between light and dark
themes.

---

## 5. BASIC dialects and plugins

**Tools → BASIC Dialect** selects which BASIC the IDE tokenizes, highlights and
documents. **Standard BASIC V2** is the default. Bundled dialects include:

- Commodore BASIC 3.5, 4.0 and 7.0
- MEGA65 BASIC 65
- Simons' BASIC
- Vision BASIC 1.1
- VIC-20 Super Expander
- Commander X16 BASIC
- Final Cartridge III BASIC

The chosen dialect changes more than highlighting: it also decides which
emulator **Run** launches. A BASIC 7.0 program routes to VICE `x128`, a BASIC 65
program to xemu, a BASIC 4.0 program to VICE `xpet`, a VIC-20 Super Expander
program to VICE `xvic`, and everything else to your preferred C64 emulator.

Routing follows the dialect's declared `machine`, because load addresses alone
are ambiguous — PET BASIC 4 and the VIC-20 Super Expander both start at $0401,
and Final Cartridge III shares $2001 with MEGA65 BASIC 65.

### Plugin format

A dialect is a JSON file with a `.c64basic` extension describing the dialect's
name, load address, target machine, activation `SYS`, token prefixes, and its
keyword table.
Each keyword carries its token bytes, category, syntax string, parameter list,
description and an example. That documentation drives both the hover tooltips in
the editor and the reference panel's Commands tab, which rebuilds whenever you
change dialect — so a plugin with good keyword documentation is immediately
browsable and searchable.
Plugins may also define assembler mnemonics, composite keywords (like
`MOB SET`), and dialect-specific abbreviations.

The optional `machine` field names the target machine — `c64`, `c128`, `vic20`,
`pet` or `mega65` — and is what selects the emulator. A plugin that omits it
(or names a machine the IDE has no target for, such as Plus/4) falls back to
routing by load address.

The submenu provides:

- **Install Plugin…** — validates and installs a `.c64basic` file, warning if a
  version of that dialect is already installed.
- **Edit Plugin…** — opens the built-in plugin editor.
- **Reveal Plugins Folder** — opens `~/Library/Application Support/C64IDE/Plugins`
  in Finder.

Plugins are loaded from that folder, from `~/Plugins`, and from the app bundle's
own `Resources/Plugins`.

---

## 6. Building and running

### BASIC

`⌘R` saves the file, tokenizes it into `build/<name>.prg`, bundles it onto the
project disk if one is configured, and launches the emulator that matches the
active dialect. Tokenization is done in-process — no external tools involved.
Enabling **Strip whitespace when tokenizing BASIC** removes unnecessary spaces
to save bytes on the C64.

### Assembly

`⌘R` runs the `ca65 → ld65` pipeline. Output goes to the project's output
directory (`build` by default) next to the source file. The Build tab shows the
command output, parsed errors and warnings, and timings; the console reports
`.dbg` debug info and `.map` files when those are enabled.

The pipeline defines four memory layouts: the standard PRG with a BASIC SYS stub
(what **Build & Run** uses), a raw PRG with no stub, an upper-RAM `$C000` build,
and the layout used for DATA generation. The menus expose the standard layout
and the DATA layout; the raw and `$C000` configs exist in the pipeline but have
no menu item in this build. For full control, point **customLinkerConfig** at
your own `.cfg` file.

### Build menu commands

| Command                       | Shortcut | What it does                                                  |
| ----------------------------- | -------- | ------------------------------------------------------------- |
| **Build & Run**               | `⌘R`     | Build (or tokenize) and launch.                               |
| **Build & Debug**             | `⇧⌘R`    | Build with debug info and attach the debugger. Assembly only. |
| **Build Only**                | `⌘B`     | Build without launching.                                      |
| **Stop**                      | `⌘.`     | Stop the build or the running emulator.                       |
| **Build & Save to Disk…**     | `⌥⌘D`    | Build, then write the PRG to a new or existing D64/D81.       |
| **Compile BASIC to ASM**      | `⇧⌘G`    | Compile BASIC source to 6502 assembly in a new tab.           |
| **Compile Assembly to DATA…** | —        | Assemble, then emit the result as BASIC `DATA` statements.    |
| **Import PRG as DATA…**       | —        | Turn an existing PRG into BASIC `DATA` statements.            |

**Build & Save to Disk** asks whether to create a new image or add to an
existing one; for a new image it asks D64 (1541, 170 KB) or D81 (1581, 800 KB).
For assembly it waits for the build to succeed before exporting, so the file
written is never stale.

**Compile Assembly to DATA** and **Import PRG as DATA** ask for a start line
number (default 10), a line increment (default 10) and bytes per `DATA` line
(default 12).

### The BASIC-to-assembly compiler

**Compile BASIC to ASM** (`⇧⌘G`) parses your BASIC program, runs a type
analyser over it, and generates ca65 assembly into a new `<name>_compiled.s`
tab. The console reports how many variables were classified as byte, word, float
and string — and confirms when a program contains no floating-point variables,
because that means no ROM float routines are emitted at all. Parse errors are
reported as build diagnostics with line numbers. Run `⌘R` on the generated `.s`
tab to assemble and run it.

This is also the route to source-level debugging for BASIC: compile to assembly
first, then **Build & Debug** the generated file.

### Choosing where it runs

The run target is resolved in this order:

1. A per-project emulator override, if set in Project Settings.
2. The active dialect's declared machine — MEGA65 → xemu, C128 → VICE `x128`,
   PET → VICE `xpet`, VIC-20 → VICE `xvic`, C64 → your preference below.
3. Failing that, the dialect's load address, for plugins that predate the
   `machine` field.
4. Your global **Run C64 targets with** preference — VirtualC64 or VICE `x64sc`.

Only the binary for the target you are actually launching is validated, so a
missing `xpet` never blocks a C64 run.

### VIC-20 specifics

On the VIC-20 the BASIC start address _is_ the memory configuration, so the IDE
reads the load address out of the built PRG and passes xvic a matching expansion:
$0401 → `-memory 3k` (what the Super Expander provides), $1001 → `-memory none`
(unexpanded), $1201 → `-memory 8k`. The expansion is always passed explicitly,
so a stale setting in your VICE configuration cannot relocate BASIC out from
under the program.

The Super Expander itself is a cartridge, and its keywords live in cartridge
ROM. Point **Preferences → VIC-20 → Super Expander cartridge ROM** at a ROM
image and the IDE passes it to xvic as `-cartse`. Without it the program still
loads, but every SE keyword fails with `?SYNTAX ERROR`; the build log warns when
you run an SE program with no ROM configured.

---

## 7. Debugging

Source-level debugging works on **assembled** programs. BASIC is tokenized
rather than assembled, so there is no instruction-to-line mapping; if you press
`⇧⌘R` on a `.bas` file the IDE explains this and offers a plain Build & Run.

### Workflow

1. Make sure **Generate debug info (.dbg)** is enabled in Preferences.
2. Click in the gutter to set breakpoints on the lines you care about.
3. **Build → Build & Debug** (`⇧⌘R`). The debugger window opens and attaches as
   the emulator launches.
4. Execution breaks at the entry point (`$0810` for assembly), and your gutter
   breakpoints are resolved to addresses through the `.dbg` file. On the very
   first build, before debug info exists, the IDE breaks at the entry point and
   tells you the gutter breakpoints will apply from the next build on.

Debugging requires a target with a monitor protocol: **VirtualC64**, **VICE
x64sc**, **x128** and **xpet** support it. xemu and the hardware targets do not
— the IDE warns and runs without breakpoints.

### The debugger window

**Tools → Debugger** (`⌥⌘Y`).

- **Connect** button and connection status; an **Address** field with **Go**.
- **Execution**: Continue, Pause, Step, Step Over, Step Out, Refresh Registers.
- **Registers**: PC, A, X, Y, SP and the flags byte.
- **Tools**: Set BP, Del BP, List BP, Memory, Disasm, Stack.
- **Cycles**: a running cycle count, also expressed in raster lines, with a
  Reset button — handy for raster timing work.
- A console with a `(C:$)` prompt where you can type monitor commands directly.
  The Monitor tab of the reference panel documents the command set for whichever
  target is attached.

The currently executing source line is highlighted in the editor as you step.

If the CPU jams, the debugger raises an alert and offers your options rather
than silently hanging.

### Disassembler

**Tools → Disassembler** (`⇧⌘I`) — **Load PRG…** to disassemble any program.
C64 ROM routine names are resolved automatically. Select a range of instructions
to see its cycle count. **Export ASM…** writes a source file, **Edit in IDE**
opens the disassembly in an editor tab, and **Copy All** copies everything.
The disk and tape browsers can send a file straight here.

### Memory map

**Tools → Memory Map** shows the 64K address space twice, side by side and to
the same scale: the **planned** layout parsed from the `cc65` `.cfg` linker
config, and the **built** layout parsed from the `ld65` `.map` file. It rebuilds
itself after every successful build. Click a region in the planned column to
open an inspector where plain hex `start` and `size` values can be edited and
written back to the `.cfg` file.

---

## 8. Real hardware: Ultimate 64 and MEGA65

### Ultimate 64

**Tools → U64 Settings…** — enter the U64's hostname or IP and password. The
sheet reports connection status. Then:

| Command     | Shortcut |
| ----------- | -------- |
| Run on U64  | `⌃⌘R`    |
| Load on U64 | `⌃⌘L`    |
| Reset U64   | —        |

Delivery is over the Ultimate 64's REST API.

### MEGA65

**Tools → MEGA65 Settings…** — point the IDE at your `etherload` binary. Then:

| Command        | Shortcut |
| -------------- | -------- |
| Run on MEGA65  | `⌃⌘M`    |
| Load on MEGA65 | —        |

For MEGA65 _emulation_ rather than hardware, set the dialect to MEGA65 BASIC 65
and configure the xemu (`xmega65`) path; **Run** then routes there automatically
and the toolbar Run icon changes to reflect it.

Neither hardware target supports the source-level debugger.

---

## 9. Graphics, character and sound editors

### Sprite Editor — `⇧⌘E`

24×21 sprite editing in hi-res or multi-colour mode. Palette with Sprite Color,
Background, Multi-Color 1 and Multi-Color 2 roles. Tools: Draw, Clear, Flip
Horizontal, Flip Vertical, and pixel shifting in all four directions.

Animation is built in: add, duplicate, copy, paste, delete and reorder frames,
with playback (adjustable FPS, ping-pong mode) and onion-skinning at adjustable
opacity.

Import from `.spd` (SpritePad) files or from pasted text — `DATA` statements,
assembler `.byte` lines, C arrays or hex strings are all recognised. Export as
BASIC `DATA`, assembly `.byte`, C array or hex string, copied to the clipboard.

### Character Set Editor — `⇧⌘D`

8×8 character editing across a 256-character map, with foreground and background
colour selection. Tools: Draw, Clear, Flip H, Flip V, Invert, pixel shifting and
per-character Copy/Paste. The arrow keys step through the character map. The
editor opens on the C64 ROM character set — the same set the Map Editor falls
back to — so a fresh charset can be edited a character at a time.

**Multi-Color** switches the grid to four 2-bit pixel pairs per row, drawn with
the `$D021`/`$D022`/`$D023` registers plus colour RAM; the **Pen** control picks
which of the four values the mouse paints. The bytes are unchanged by the
toggle — as on real hardware, multi-color simply reinterprets them. Flip H and
horizontal shifts move whole pixel pairs in this mode, so colours survive.

**Load ROM** pulls in either ROM character set (uppercase/graphics or
lowercase/uppercase) as a starting point; **Import…** loads a charset file
(a 2-byte PRG load address is stripped automatically); **Save .bin** — or `⌘S` —
writes raw binary. Export the selected character or the whole set as assembly,
BASIC `DATA`, or hex, and **Send to Map Editor** pushes the charset straight
into the tile map editor.

### Graphics Editor — `⌥⌘G`

Hi-res bitmap editing with undo/redo, clear and import. Reads and writes Koala
Painter (`.kla`), Art Studio (`.art`), raw binary (`.bin`), assembly (`.asm`),
BASIC `DATA` (`.bas`), and self-displaying PRG.

### Image Converter — `⌥⌘I`

Load any macOS-readable image and convert it to C64 format: **Hi-Res
(320×200)** or **Multi-Color (160×200)**, with brightness and contrast
adjustment and a choice of dithering (None, Floyd-Steinberg, or ordered Bayer).
Source and converted views sit side by side. Export as Koala, Art Studio, PRG,
assembly, BASIC `DATA` or raw binary — or write the result straight to a new or
existing D64.

### Map Editor — `⌥⌘M`

Tile map editing on a character grid. Tools: Paint, Fill, Flood, Pick and
Select, with rectangular copy and paste. Multiple layers with visibility toggles
and removal, a grid overlay, a raster overlay, and charset bank selection
(Bank 0 / Bank 1) — the editor warns if a map mixes charset banks. **Fit** zooms
the whole map into view, and **Dim** shades the layers that are not being edited.

The tile picker previews characters in the map's own colours, and the left panel
carries both the paint colour and the map's background colour (`$D021`).

The **Map ▾** menu holds **New Map…** and **Resize Map…** (1–256 characters in
each direction; a single C64 screen is 40×25), save/open, **Load Charset…**, and
the assembly (`.s`) / binary (`.bin`) exports. `⌘S` saves the map.

**Send to Map Editor** in the Character Set Editor hands the charset over and
switches on **Live Charset Sync**, so later edits to the glyphs appear in the map
as you make them. The map keeps its own background colour; toggle the sync off
from the **Map ▾** menu. If the charset is in multi-color mode, cells whose
colour RAM value is 8–15 render as multi-color — the same rule the VIC-II uses —
and those colours are marked in the paint palette.

Undo is supported throughout.

### SID Editor — `⇧⌘M`

A tracker-style editor for the SID chip with live audio preview.

- **Voices** 1–3, each with waveform selection (TRI, SAW, PUL, NOI) and pulse
  width.
- **ADSR envelope** with a draggable envelope display.
- **Filter** section: cutoff, resonance, filter type and per-voice routing.
- **Instruments** — create and rename reusable sound definitions.
- **Tracker** — pattern-based sequencing (`Pat 00`, `Pat 01`, …) with note entry
  and adjustable playback speed.
- Master volume, `♪ Preview` for auditioning.

Open and save SID songs, and export the song as assembly or BASIC.

### Character ROM Viewer — `⌥⌘C`

Browse the 256 characters of the C64 character ROM with a zoomed preview and
per-character metadata (screen code, PETSCII code, byte values).

---

## 10. Disk and tape images

### Disk Browser — `⇧⌘K`

Works with **D64** (1541) and **D81** (1581) images.

- **Open…** an existing image, or **New D64…** / **New D81…** to create one
  (you supply the disk name and two-character ID).
- The file list shows filename, type and block count, with free blocks
  remaining.
- **Add File…** writes a PRG into the image; **Extract PRG…** pulls one out;
  **Rename…** and **Delete** operate on the selected entry.
- **Open in IDE** loads a file into an editor tab; **Disassemble** sends it to
  the disassembler.
- **Save**, **Save As…** and **Reload** manage the image itself; the browser
  warns about unsaved changes and about overwriting an existing filename.

C64 filenames containing characters macOS dislikes (`/`, `:`, `\`) are
sanitized on extraction, and filename fields are forced to uppercase to match
PETSCII conventions.

### Tape Browser — `⇧⌘T`

Handles **TAP** tape images and **T64** archives.

- **Open…** a TAP or T64; **New T64** creates an archive.
- TAP parsing is configurable: minimum pilot pulses, the medium/long pulse
  boundary in units, and a **Preset** picker with a **Custom** option. Change
  the settings and hit **Re-parse**; the **Parse Log** explains what the parser
  found and why.
- Entries show filename and address range, and are marked **EDITABLE** or
  **READ ONLY** depending on the container.
- **Add PRG…**, **Extract PRG…**, **Rename**, **Delete**, **Open in IDE** and
  **Disassemble** work as in the disk browser.
- **Export to D64…** / **Export to D81…** moves tape contents onto a new or
  existing disk image.

---

## 11. Reference and utility tools

### Number Converter — `⇧⌘U`

Converts a 16-bit value between DEC, HEX, BIN and OCT simultaneously, shows the
high and low bytes separately, and offers a clickable bit grid for toggling
individual bits. An operations row applies AND, OR, XOR, NOT, SHL and SHR
against a second operand, and a quick-preset row jumps to commonly used values.

### PETSCII Map — `⇧⌘P`

A 16×16 grid of the PETSCII character set showing each character's glyph,
decimal/hex/binary code and screen code, with quick-copy buttons that produce
the corresponding BASIC or assembly syntax.

### Reference panel tabs

Covered in [section 2](#2-the-main-window) — Commands, Memory, ROM, Colors,
PETSCII, Monitor and Variables. Several of these have their own search field,
and the panel follows the cursor: put the caret on a keyword and its
documentation is selected for you.

### Linker config editing

The Memory Map window's inspector edits `.cfg` files surgically — it replaces
just the text span of the value you changed, leaving all comments, formatting
and unrelated blocks intact.

---

## 12. The AI assistant

The **AI** tab in the console panel is a chat assistant that can see what you
are working on.

Click the gear icon to open settings:

- **API Provider** — Anthropic, OpenAI, Gemini, or a **Custom** endpoint. The
  custom option takes a base URL, which lets you point at a locally hosted
  server that speaks the same API.
- **API Key** — stored in the macOS Keychain, separately per provider. **Remove
  Key** deletes it.
- **Model** — pick from the catalog, or hit **Refresh** to fetch the provider's
  current model list.
- **Enable extended thinking** — for models that support it.
- **Max output tokens** — within the selected model's range.

Each message you send includes a context block describing the active file name
and type, its contents, your current selection, the active BASIC dialect, and
any errors from the last build. Content is truncated to stay within token
limits. Code blocks in replies have an **Open in New Tab** action that drops the
code straight into a new editor tab with the right file type.

Session token usage is shown next to the input field.

Sending code to a third-party API means it leaves your machine — worth keeping
in mind for anything you would rather not share.

---

## 13. Preferences and appearance

**C64 IDE → Preferences…** (`⌘,`):

| Section           | Contents                                                                                                                                                               |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Tool Paths**    | `ca65`, `ld65`, VICE `x64sc` / `x128` / `xpet` / `xvic`, xemu `xmega65`. **Auto-Detect Paths** fills these in.                                                         |
| **C64 Emulator**  | VirtualC64 (embedded) or VICE x64sc (external) for C64 targets.                                                                                                        |
| **Build Options** | Generate debug info (.dbg) · Generate listing file (.lst) · Auto-run in VICE after build · Strip whitespace when tokenizing BASIC · Show example file on launch.       |
| **VICE Emulator** | C64 model (PAL/NTSC variants, Drean, Japanese, C64 GS), SID model (6581, 8580, 8580 + digiboost), video standard (PAL 50 Hz / NTSC 60 Hz).                             |
| **C64 ROMs**      | KERNAL, BASIC and Character ROM paths. Applied to VirtualC64 and VICE `x64sc` only — they are C64 images, so they are not handed to the VIC-20, PET or C128 emulators. |
| **VIC-20**        | Super Expander cartridge ROM image, passed to xvic as `-cartse`.                                                                                                       |

Validation warnings appear live as you edit paths and are debounced so they do
not fire on every keystroke.

Other appearance controls: the toolbar theme button (light/dark), and
**View → Editor Font** for the editor typeface and size.

---

## 14. Keyboard shortcut reference

### File

| Shortcut | Command           |
| -------- | ----------------- |
| `⌘N`     | New BASIC File    |
| `⇧⌘N`    | New Assembly File |
| `⌥⌘N`    | New Project…      |
| `⌘O`     | Open…             |
| `⇧⌘O`    | Open Project…     |
| `⌘S`     | Save              |
| `⇧⌘S`    | Save As…          |
| `⌥⌘S`    | Save Project      |
| `⇧⌘,`    | Project Settings… |
| `⌘W`     | Close Tab         |
| `⇧⌘W`    | Close Window      |
| `⌘,`     | Preferences…      |
| `⌘Q`     | Quit              |

### Edit

| Shortcut            | Command                      |
| ------------------- | ---------------------------- |
| `⌘Z` / `⇧⌘Z`        | Undo / Redo                  |
| `⌘X` `⌘C` `⌘V` `⌘A` | Cut, Copy, Paste, Select All |
| `⌘F`                | Find…                        |
| `⇧⌘L`               | Renumber BASIC Lines…        |

### Build

| Shortcut | Command               |
| -------- | --------------------- |
| `⌘R`     | Build & Run           |
| `⇧⌘R`    | Build & Debug         |
| `⌘B`     | Build Only            |
| `⌘.`     | Stop                  |
| `⌥⌘D`    | Build & Save to Disk… |
| `⇧⌘G`    | Compile BASIC to ASM  |
| `⌃⌘R`    | Run on U64            |
| `⌃⌘L`    | Load on U64           |
| `⌃⌘M`    | Run on MEGA65         |

### Tools

| Shortcut | Command                  |
| -------- | ------------------------ |
| `⇧⌘E`    | Sprite Editor            |
| `⇧⌘D`    | Character Set Editor     |
| `⌥⌘C`    | ROM Character Set Viewer |
| `⌥⌘Y`    | Debugger                 |
| `⇧⌘I`    | Disassembler             |
| `⇧⌘K`    | Disk Browser             |
| `⇧⌘T`    | Tape Browser             |
| `⇧⌘M`    | SID Editor               |
| `⌥⌘G`    | Graphics Editor          |
| `⇧⌘U`    | Number Converter         |
| `⇧⌘P`    | PETSCII Map              |
| `⌥⌘I`    | Image Converter          |
| `⌥⌘M`    | Map Editor               |

### View

| Shortcut    | Command                              |
| ----------- | ------------------------------------ |
| `⌘+` / `⌘-` | Increase / Decrease editor font size |
| `⌘0`        | Reset editor font size               |
| `⌥⌘R`       | Toggle Reference Panel               |
| `⇧⌘Y`       | Toggle Console                       |

---

## 15. Where the IDE keeps its files

| Path                                                     | Contents                                                                                                             |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `~/Library/Application Support/C64IDE/c64ide_build.json` | Global build configuration: tool paths, emulator preference, ROM paths, build options.                               |
| `~/Library/Application Support/C64IDE/Plugins/`          | Installed BASIC dialect plugins (`.c64basic`). Also scanned: `~/Plugins/` and the app bundle's `Resources/Plugins/`. |
| `<project>/<name>.c64proj`                               | Project file: metadata, build options, disk configuration, session state and breakpoints.                            |
| `<source dir>/build/`                                    | Build output — `.prg`, `.o`, `.map`, `.dbg`, `.lst`, and bundled disk images. Configurable per project.              |
| macOS Keychain                                           | AI provider API keys, one entry per provider.                                                                        |
| `NSUserDefaults`                                         | AI provider selection, model, thinking and token settings; editor font; theme; recent projects.                      |

---

## 16. Troubleshooting

**"ca65 not found" / "ld65 not found".** Install `cc65` (`brew install cc65`)
and click **Auto-Detect Paths** in Preferences, or browse to the binaries
manually. BASIC-only work does not need them.

**"VICE (x64sc) not found".** The IDE tries `/Applications/VICE/x64sc.app/…`,
`/opt/homebrew/bin/x64sc` and `/usr/local/bin/x64sc` and adopts a working one
for the current session if it finds it — but it does not save that change. Set
the path in Preferences to make it stick.

**Emulator warnings for tools I don't use.** Only the target you are actually
launching is validated at run time. Warnings in the Preferences panel are
informational; they do not block a build.

**Build & Debug says it is for assembly.** Correct — BASIC is tokenized, not
assembled, so there is no line mapping. Compile the BASIC to assembly first
(`⇧⌘G`), then debug the generated `.s` file.

**Breakpoints do not trigger on the first debug run.** Debug info has to exist
before gutter breakpoints can be resolved to addresses. The first run breaks at
the entry point; from the next build on, your breakpoints work. Also confirm
**Generate debug info (.dbg)** is enabled.

**Breakpoints stopped matching.** They are resolved against the last build's
`.dbg` file. Rebuild after changing code that shifts the memory layout.

**"File must be saved before building."** The build pipeline works from files on
disk. The IDE prompts you to save and then continues automatically.

**Colours look wrong in VirtualC64, or the machine behaves oddly.** Point the
C64 ROM paths at genuine Commodore ROM dumps. Without them VirtualC64 falls back
to the MEGA65 OpenROMs, which are less accurate.

**Run launches the wrong emulator.** A per-project override wins first, then the
active dialect's machine (C128 → `x128`, MEGA65 → xemu, PET → `xpet`,
VIC-20 → `xvic`), then your global preference. Check **Tools → BASIC Dialect**
and Project Settings. A hand-written plugin with no `machine` field is routed by
load address, which cannot tell a PET program from a VIC-20 Super Expander one —
add `"machine": "vic20"` to fix it.

**Super Expander keywords give ?SYNTAX ERROR.** The program loaded, but the
cartridge ROM is missing. Set **Preferences → VIC-20 → Super Expander cartridge
ROM**.

**Disk export produced a stale program.** It should not — for assembly the
export waits for the build to complete. If the build failed, the console says
"Build failed. Disk export cancelled." and nothing is written.

**"Failed to write — disk may be full."** A D64 holds 170 KB, a D81 800 KB. The
Disk Browser shows the free block count.

**Renumbering was refused.** The renumber reports the specific references it
could not rewrite. Fix those (usually computed `GOTO`s or references to lines
that do not exist) and try again.

---

## Getting help

- Website: [gopherbrokesoftware.com](https://gopherbrokesoftware.com/)
- Contact: dnsgeek@duck.com
- Updates: **C64 IDE → Check for Updates…**
- Security issues: see [SECURITY.md](SECURITY.md)

Licensed under the GNU General Public License, version 2. See
[LICENSE](LICENSE).
