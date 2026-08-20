# C64 IDE

A native macOS integrated development environment for the Commodore 64 and its
extended family of 8-bit machines. Write, build, debug, and run 6502 assembly
and BASIC programs, then send them straight to an emulator or real hardware —
all without leaving the app.

The source code in this repository is the open-source release of the C64 IDE
available from [gopherbrokesoftware.com](https://gopherbrokesoftware.com/).

---

## Features

### Editing & languages
- **6502/6510 assembly** editing with syntax highlighting, built on the
  `ca65` / `ld65` toolchain.
- **BASIC** editing with support for many dialects through a plugin system,
  including Commodore BASIC V2, 3.5, 4.0 and 7.0, MEGA65 BASIC 65, Simon's
  BASIC, Vision BASIC, the VIC-20 Super Expander, and Commander X16 BASIC.
- Line-numbered gutter, PETSCII-aware editing, configurable editor fonts, and
  inline reference tooltips.
- BASIC utilities: renumbering, shortcut expansion, and tokenization support.

### Build & run
- One-click **Build & Run** through the `ca65 → ld65` pipeline with a parsed
  error/warning list.
- Multiple build layouts: standard PRG with a BASIC SYS stub, raw PRG, upper-RAM
  ($C000) builds, and "assembly to BASIC `DATA`" generation.
- Assemble to disk bundles and export to disk images.

### Debugging
- **Source-level debugger** with breakpoints, driven through the VICE monitor
  protocol, that maps machine addresses back to your source lines using
  assembler debug info.
- 6502 **disassembler** with C64 ROM symbol resolution.
- **Memory map viewer** generated from the linker `.map` file.

### Graphics & audio tools
- **Sprite editor** and **character set editor**.
- **Graphics/bitmap editor** and an **image format converter**.
- **Tile map editor** with undo support.
- **SID editor** with a live audio engine for the C64 sound chip.
- **Character ROM viewer** and **PETSCII character map**.

### Disk & tape images
- Browse and manipulate **D64** and **D81** disk images.
- Read and write **TAP** tape images.

### Emulators & hardware targets
Send a freshly built program to any of:
- **VirtualC64** — embedded, C64.
- **VICE** — `x64sc` (C64), `x128` (C128 / BASIC 7.0), `xpet` (PET / BASIC 4.0)
  and `xvic` (VIC-20 / Super Expander).
- **xemu (xmega65)** — MEGA65 / BASIC 65.
- **Ultimate 64** — real hardware over its REST API.
- **MEGA65** — real hardware over `etherload`.

### Project management
- Project files (`.c64proj`) with per-project settings and build configuration.
- Built-in **project templates** (assembly and BASIC game starters).
- **Git** integration for version control of your projects.

### AI assistance
- Optional **Claude** integration that is aware of your IDE context, for help
  while you write code.

### Extra utilities
- Number base converter, plugin editor for BASIC dialects, and more.

---

## Requirements

- macOS (built with Cocoa, AppKit, and SwiftUI).
- The [`cc65`](https://cc65.github.io/) toolchain (`ca65` / `ld65`) for
  assembling and linking.
- One or more of the supported emulators or hardware devices to run your
  programs:
  - [VICE](https://vice-emu.sourceforge.io/) (`x64sc`, `x128`, `xpet`, `xvic`)
  - [xemu](https://github.com/lgblgblgb/xemu) (for MEGA65)
  - An Ultimate 64 or MEGA65 for on-hardware execution.

---

## Building from source

This is an Xcode project written in Swift with a small amount of Objective-C++
(for the embedded VirtualC64 bridge).

### Steps

1. Clone this repository:
   ```sh
   git clone https://github.com/DNSGeek/C64IDE-OpenSource.git
   cd C64IDE-OpenSource
   ```

2. Install `ca65` and `ld65` (for example via Homebrew: `brew install cc65`)
   so the build pipeline can find them, then point the IDE at them in its
   build preferences if they are not on the default search path.

3. Build the VirtualC64 static libraries. The embedded C64 emulator is powered
   by [VirtualC64](https://github.com/dirkwhoffmann/virtualc64) by Dirk
   Hoffmann. Its C++ source must be cloned **as a sibling** of this repository
   (the Xcode project references headers via `$(SRCROOT)/../virtualc64`), and
   its static libraries built with CMake:
   ```sh
   # Clone VirtualC64 next to C64IDE-OpenSource
   git clone https://github.com/dirkwhoffmann/virtualc64.git ../virtualc64

   # Build the static libraries
   mkdir ../virtualc64/build
   cd ../virtualc64/build
   cmake ../VCCore -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
   make -j$(sysctl -n hw.logicalcpu)

   # Copy them into the project
   cd -
   mkdir -p VirtualC64/lib
   find ../virtualc64/build -name "*.a" -exec cp {} VirtualC64/lib/ \;
   ```

4. Open `C64IDE.xcodeproj` and build the app target (⌘B).

---

## Repository layout

| Directory | Contents |
|-----------|----------|
| `Assembler/` | Build pipeline, linker configuration, and assembly-to-data tools |
| `BASIC/` | BASIC lexer, parser, code generation, dialect plugins, and tokenizer |
| `Debugger/` | Source-level debugger and VICE monitor client |
| `Disassembler/` | 6502 disassembler and ROM symbol tables |
| `GfxEditor/` | Bitmap/graphics editor and image converter |
| `MapEditor/` | Tile map editor |
| `SIDEditor/` | SID chip editor and audio engine |
| `D64/`, `TAP/` | Disk and tape image handling |
| `VirtualC64/`, `U64/`, `MEGA65/` | Emulator and hardware target integration |
| `RunInEmulator/` | Run-target abstraction and emulator coordination |
| `Project/` | Project model, templates, and Git integration |
| `Views/` | Editor, tool windows, and UI controllers |
| `SyntaxHighlighting/` | Assembly and BASIC syntax highlighters |
| `Claude/` | Claude AI integration |
| `Models/` | Shared data models and C64 reference data |
| `Resources/` | Assets, BASIC dialect plugins, and project templates |

---

## License

This project is licensed under the **GNU General Public License, version 2**.
See the [LICENSE](LICENSE) file for the full text.

## Security

Please see [SECURITY.md](SECURITY.md) for the security policy and instructions
on how to responsibly report a vulnerability.
