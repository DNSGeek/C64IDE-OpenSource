// VC64Bridge.h
// Objective-C++ wrapper around the VirtualC64 C++ library.
//
// This is the ONLY file Swift sees. It exposes a clean ObjC interface
// with no C++ types leaking through. Import this in your bridging header.
//
// Usage in MyApp-Bridging-Header.h:
//   #import "VC64Bridge.h"

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// ─────────────────────────────────────────────────────────────
// MARK: - Register State
// ─────────────────────────────────────────────────────────────

/// Snapshot of 6502 CPU registers. Plain struct designed to cross the ObjC/C++
/// bridge cleanly without boxing or pointer indirection.
typedef struct {
  uint16_t pc;
  uint8_t a, x, y, sp;
  uint8_t flags; // NV-BDIZC (6502 status register)
} VC64RegisterState;

/// Convenience bit-tests on the flags byte.
static inline BOOL VC64FlagNegative(VC64RegisterState s) {
  return (s.flags & 0x80) != 0;
}
static inline BOOL VC64FlagOverflow(VC64RegisterState s) {
  return (s.flags & 0x40) != 0;
}
static inline BOOL VC64FlagBreak(VC64RegisterState s) {
  return (s.flags & 0x10) != 0;
}
static inline BOOL VC64FlagDecimal(VC64RegisterState s) {
  return (s.flags & 0x08) != 0;
}
static inline BOOL VC64FlagIRQ(VC64RegisterState s) {
  return (s.flags & 0x04) != 0;
}
static inline BOOL VC64FlagZero(VC64RegisterState s) {
  return (s.flags & 0x02) != 0;
}
static inline BOOL VC64FlagCarry(VC64RegisterState s) {
  return (s.flags & 0x01) != 0;
}

// ─────────────────────────────────────────────────────────────
// MARK: - Keyboard
// ─────────────────────────────────────────────────────────────

/// Swift-visible identifiers for every key on the C64 keyboard.
///
/// These map 1:1 onto VCCore's C64Key named constants in the bridge .mm.
/// autoType: handles ordinary text entry; this enum exists for the keys
/// autoType can't reach as discrete press/release events — Backspace (DEL),
/// the four cursor directions, RUN/STOP, RESTORE, the function keys, and the
/// modifiers you need to hold down (SHIFT / C= / CTRL).
///
/// Note on combined keys: the real C64 has single physical keys that the
/// host keyboard splits in two. CRSR LEFT/RIGHT and CRSR UP/DOWN are one key
/// each (shifted = the reverse direction); likewise F1/F2 etc. The "plain"
/// codes press the bare key; the explicit *Shift* helpers below let Swift ask
/// for the shifted direction without managing leftShift itself.
typedef NS_ENUM(NSInteger, VC64KeyCode) {
  VC64KeyDelete, // DEL — acts as Backspace on the C64
  VC64KeyReturn,
  VC64KeyHome, // CLR/HOME (unshifted = HOME)
  VC64KeyRunStop,
  VC64KeyRestore, // not in the keyboard matrix (NMI line)
  VC64KeySpace,

  // Cursor keys. The C64 has TWO physical cursor keys, each doing two
  // directions via shift. Press these bare for down/right; use the
  // -pressCursor… helpers (or hold a shift) for up/left.
  VC64KeyCursorLeftRight, // bare = RIGHT, shifted = LEFT
  VC64KeyCursorUpDown,    // bare = DOWN,  shifted = UP

  // Function keys. Bare = odd (F1/F3/F5/F7), shifted = even (F2/F4/F6/F8).
  // NS_SWIFT_NAME pins the Swift spelling: without it the importer stops
  // lowercasing at the digit and yields .f1F2 (capital F), which is easy
  // to get wrong at the call site. These give clean .f1f2/.f3f4/… names.
  VC64KeyF1F2 NS_SWIFT_NAME(f1f2),
      VC64KeyF3F4 NS_SWIFT_NAME(f3f4),
          VC64KeyF5F6 NS_SWIFT_NAME(f5f6),
              VC64KeyF7F8 NS_SWIFT_NAME(f7f8),

                  // Modifiers — hold these down across other presses.
                  VC64KeyLeftShift, VC64KeyRightShift, VC64KeyCommodore,
                  VC64KeyControl,
                  VC64KeyShiftLock, // latching SHIFT (not in the matrix)
          };

// ─────────────────────────────────────────────────────────────
// MARK: - Emulator messages (mirrors vc64::Msg)
// ─────────────────────────────────────────────────────────────

/// Subset of VirtualC64 messages that the IDE actually cares about.
/// Add entries here as you need them — the handler in VC64Bridge.mm
/// maps from the full vc64::Msg enum to these.
typedef NS_ENUM(NSInteger, VC64Message) {
  VC64MessagePowerOn,
  VC64MessagePowerOff,
  VC64MessageRun,
  VC64MessagePause,
  VC64MessageReset,
  VC64MessageWarpOn,     // emulator entered warp mode (value=1)
  VC64MessageWarpOff,    // emulator exited warp mode  (value=0)
  VC64MessageBreakpoint, // CPU hit a breakpoint
  VC64MessageWatchpoint, // CPU hit a watchpoint
  VC64MessageCPUJammed,  // CPU halted on an illegal opcode (KIL/JAM)
  VC64MessageScriptDone, // asyncExecScript finished
  VC64MessageScriptAbort,
  VC64MessageScriptPause,      // script hit a 'wait' command
  VC64MessageRetroShellUpdate, // console text changed (isDirty)
  VC64MessageDiskInserted,
  VC64MessageDiskEjected,
  VC64MessageUnknown,
};

// ─────────────────────────────────────────────────────────────
// MARK: - Video standard
// ─────────────────────────────────────────────────────────────

/// Video standard of the emulated machine. Mirrors the PAL/NTSC split of
/// VCCore's VICII revision option without leaking the full revision enum
/// into Swift.
typedef NS_ENUM(NSInteger, VC64Standard) {
  VC64StandardPAL,
  VC64StandardNTSC,
};

// ─────────────────────────────────────────────────────────────
// MARK: - Delegate
// ─────────────────────────────────────────────────────────────

@class VC64Bridge;

/// Implement this in Swift to receive emulator events.
/// All callbacks are delivered on the main thread.
@protocol VC64BridgeDelegate <NSObject>
@optional
- (void)vc64:(VC64Bridge *)bridge didReceiveMessage:(VC64Message)message;
- (void)vc64:(VC64Bridge *)bridge didHitBreakpointAtPC:(uint16_t)pc;
- (void)vc64:(VC64Bridge *)bridge didHitWatchpointAtPC:(uint16_t)pc;

/// The CPU executed an illegal opcode (KIL/JAM) and halted. `pc` is the
/// address of the offending instruction (the start of it, not the operand
/// bytes), so the IDE can jump straight to the dead instruction in source.
/// The emulator is interrupted when this fires; the machine won't continue
/// until reset.
- (void)vc64:(VC64Bridge *)bridge didJamAtPC:(uint16_t)pc;
- (void)vc64BridgeRetroShellDidUpdate:(VC64Bridge *)bridge;
@end

// ─────────────────────────────────────────────────────────────
// MARK: - VC64Bridge
// ─────────────────────────────────────────────────────────────

/// The main bridge object. Create one instance and keep it alive for
/// the lifetime of the emulator window.
@interface VC64Bridge : NSObject

@property(nonatomic, weak, nullable) id<VC64BridgeDelegate> delegate;

/// YES after -launch has been called and ROMs are loaded.
@property(nonatomic, readonly) BOOL isReady;
@property(nonatomic, readonly) BOOL isPoweredOn;
@property(nonatomic, readonly) BOOL isRunning;
@property(nonatomic, readonly) BOOL isPaused;

// ─────────────────────────────────────────────────────────────
// MARK: Lifecycle
// ─────────────────────────────────────────────────────────────

/// Designated initialiser. Does NOT start the emulator thread.
- (instancetype)init;

/// Load ROMs and start the emulator thread.
/// Call once, before any other method.
/// @param kernalROM  Path to kernal.rom (or nil to use built-in OpenROM)
/// @param basicROM   Path to basic.rom  (or nil)
/// @param charROM    Path to char.rom   (or nil)
/// @param error      On failure, describes the problem.
- (BOOL)launchWithKernalROM:(nullable NSString *)kernalROM
                   basicROM:(nullable NSString *)basicROM
                    charROM:(nullable NSString *)charROM
                      error:(NSError **)error;

/// Power the emulator on (no-op if already on).
- (void)powerOn;

/// Power the emulator off.
- (void)powerOff;

/// Hard reset (equivalent to power-cycling).
- (void)hardReset;

/// Soft reset (equivalent to pulling the reset line).
- (void)softReset;

/// Halt the emulator thread. Call before releasing this object.
- (void)halt;

/// Must be called from your display-link / CAMetalLayer vsync callback.
- (void)wakeUp;

// ─────────────────────────────────────────────────────────────
// MARK: Run Control
// ─────────────────────────────────────────────────────────────

- (void)run;
- (void)pause;
- (void)warpOn;
- (void)warpOff;

/// Configure automatic warp-on-boot. While the emulated CPU clock is under
/// `seconds` of *emulated* time, the emulator runs in warp mode, then drops
/// to realtime on its own — no manual warpOff needed. This is the clean way
/// to cut the ~1–2s of C64 boot/BASIC-ready wait: set it once before powerOn.
///
/// Measured in emulated seconds, so the behaviour is deterministic regardless
/// of host speed. Pass 0 to disable (the VCCore default). A typical C64 cold
/// boot to READY is ~2s of emulated time, so 3–4 covers it with headroom.
- (void)setWarpBootDuration:(NSInteger)seconds;

/// Current warp-on-boot duration in emulated seconds (0 = disabled).
- (NSInteger)warpBootDuration;

// ─────────────────────────────────────────────────────────────
// MARK: Media
// ─────────────────────────────────────────────────────────────

/// Flash a PRG file directly into C64 memory and run it.
/// This is the clean equivalent of LOAD+RUN — no disk needed.
/// @param path  Absolute path to the .prg file.
- (BOOL)flashPRG:(NSString *)path error:(NSError **)error;

/// Insert a D64 or D81 disk image into the specified drive (8 or 9).
/// @param path        Absolute path to the disk image.
/// @param driveNumber 8 or 9.
/// @param writeProtect YES to write-protect the virtual disk.
- (BOOL)insertDisk:(NSString *)path
       driveNumber:(NSInteger)driveNumber
      writeProtect:(BOOL)writeProtect
             error:(NSError **)error;

/// Eject the disk in the specified drive.
- (void)ejectDiskFromDrive:(NSInteger)driveNumber;

/// Save the current disk in a drive back to a D64/D81 image.
- (BOOL)saveDiskInDrive:(NSInteger)driveNumber
                 toPath:(NSString *)path
                  error:(NSError **)error;

/// Type a string into the C64 keyboard (uses the autoType daemon).
- (void)autoType:(NSString *)text;

// ─────────────────────────────────────────────────────────────
// MARK: Keyboard — discrete key events
// ─────────────────────────────────────────────────────────────

/// Press (and hold) a single key. The key stays down until -releaseKey:
/// (or -releaseAllKeys) is called, so this is how you handle held modifiers
/// and key-repeat for things like Backspace and the cursor keys.
///
/// IMPORTANT: the C64 only scans its keyboard matrix ~60×/sec. If you press
/// several keys back-to-back in the same runloop tick, the machine may miss
/// some. For multi-key combos prefer -pressKey:withModifier: which staggers
/// the modifier ahead of the key for you.
- (void)pressKey:(VC64KeyCode)key;

/// Release a previously-pressed key.
- (void)releaseKey:(VC64KeyCode)key;

/// Toggle a key's state (used for latching keys like SHIFT LOCK, but works
/// on any key).
- (void)toggleKey:(VC64KeyCode)key;

/// Release every currently-held key. Good for a "panic" reset of stuck
/// modifiers, e.g. on window blur.
- (void)releaseAllKeys;

/// YES if the given key is currently held down in the matrix.
- (BOOL)isKeyPressed:(VC64KeyCode)key;

/// Press `key` while `modifier` is held, then release both. The modifier is
/// scheduled slightly ahead of the key so the matrix scan sees it first.
/// Use this for shifted directions (e.g. CursorUpDown + LeftShift = cursor up)
/// and shifted function keys (F1F2 + LeftShift = F2).
- (void)pressKey:(VC64KeyCode)key withModifier:(VC64KeyCode)modifier;

/// Convenience wrappers for the shifted cursor directions, so callers don't
/// have to remember which bare key + shift produces which direction.
- (void)pressCursorUp;
- (void)pressCursorDown;
- (void)pressCursorLeft;
- (void)pressCursorRight;

// ─────────────────────────────────────────────────────────────
// MARK: Video
// ─────────────────────────────────────────────────────────────

/// Copy the current stable frame into a caller-supplied RGBA buffer.
///
/// Call this from your Metal render loop, between -lockTexture /
/// -unlockTexture, or use the convenience -updateMetalTexture:device: below.
///
/// @param buffer   Destination buffer. Must be at least width*height*4 bytes.
/// @param width    Receives the texture width in pixels.
/// @param height   Receives the texture height in pixels.
- (void)lockTexture;
- (void)unlockTexture;
- (nullable const uint32_t *)texturePointerWidth:(NSInteger *)width
                                          height:(NSInteger *)height;

/// Convenience: upload the current frame to a Metal texture.
/// Creates the texture on first call; recreates it if dimensions change.
/// Returns nil if the emulator isn't running.
- (nullable id<MTLTexture>)updateMetalTextureOnDevice:(id<MTLDevice>)device;

/// Set the emulated machine's video standard by switching the VICII
/// revision (PAL 6569 R3 vs NTSC 6567) and the power-grid frequency
/// (which drives the CIA TOD clocks: 50 Hz PAL, 60 Hz NTSC).
///
/// Safe to call any time after -launch..., including on a powered-on
/// machine -- VCCore applies revision changes on the fly, same as the
/// VirtualC64 app's settings panel. For a clean boot in the desired
/// standard, call it between -launch... and -powerOn.
- (void)setVideoStandard:(VC64Standard)standard;

/// The machine's current video standard, derived from the live VICII
/// revision. Reliable after -launch...; returns PAL before that.
- (VC64Standard)videoStandard;

/// Return the UV coordinates of the visible C64 picture area inside the
/// full emulator texture. VCCore's texture is 520x312 — the full PAL frame
/// including off-screen border / vblank / hblank padding. The actual visible
/// C64 picture is roughly 403x284 centred inside it.
///
/// The returned values are normalised to [0,1]:
///   - uMin/uMax: horizontal span of the visible region (0=left, 1=right)
///   - vMin/vMax: vertical span (0=top, 1=bottom)
///
/// Pass nil for any output you don't care about. Returns false if the
/// emulator isn't running (in which case the outputs are unmodified).
- (BOOL)getVisibleAreaUMin:(nullable double *)uMin
                      uMax:(nullable double *)uMax
                      vMin:(nullable double *)vMin
                      vMax:(nullable double *)vMax;

// ─────────────────────────────────────────────────────────────
// MARK: Audio
// ─────────────────────────────────────────────────────────────

/// Inform VCCore of the host audio output rate. VCCore's Adaptive Sample
/// Rate (ASR) uses this to time-align SID sample production with the host
/// audio device drain rate, minimising underruns/overruns.
///
/// Should be called once after the bridge is launched and again whenever
/// the host audio engine's render rate changes (e.g. user picks a
/// different output device).
- (void)setHostSampleRate:(double)hz;

/// Pull stereo samples from VCCore's audio ringbuffer into an interleaved
/// destination buffer (L, R, L, R, ...). Returns the number of FRAMES
/// actually written; if VCCore is starved, this can be less than `frames`
/// and the caller should zero-fill the remainder.
///
/// Thread safety: VCCore's audio port uses an internal lock-free ring
/// for stereo sample storage, so this method is safe to call from a
/// real-time audio render thread.
///
/// @param buffer   Destination buffer, sized at least `frames * 2 *
/// sizeof(float)`.
/// @param frames   Number of stereo frames requested (one frame = L + R).
/// @return         Number of frames actually written (0..frames).
- (NSInteger)copyInterleavedSamples:(float *)buffer frames:(NSInteger)frames;

/// Pull stereo samples into TWO separate buffers (planar / non-interleaved).
/// This is the format AVAudioEngine's internal nodes (mainMixerNode etc.)
/// require — interleaved is only accepted at the output node edge.
///
/// Thread-safety identical to copyInterleavedSamples:.
///
/// @param left     Destination buffer for the left channel  (>= frames floats).
/// @param right    Destination buffer for the right channel (>= frames floats).
/// @param frames   Number of stereo frames requested.
/// @return         Number of frames actually written (0..frames).
- (NSInteger)copyStereoSamplesLeft:(float *)left
                             right:(float *)right
                            frames:(NSInteger)frames;

/// Pull mono samples (left+right summed) into a single-channel destination
/// buffer. Useful for hardware that doesn't have a stereo output, or for
/// waveform visualisation. Returns the number of SAMPLES actually written.
- (NSInteger)copyMonoSamples:(float *)buffer count:(NSInteger)count;

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — Execution control
// ─────────────────────────────────────────────────────────────

- (void)stepInto;
- (void)stepOver;
- (void)stepCycle;
- (void)finishLine;
- (void)finishFrame;

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — CPU / Memory inspection
// ─────────────────────────────────────────────────────────────

/// Returns the current CPU register state. Valid while paused.
- (VC64RegisterState)registers;

/// Read a single byte from C64 memory (CPU address space).
- (uint8_t)readByte:(uint16_t)address;

/// Read a range of bytes. Returns NSData of length (end - start + 1).
- (NSData *)readMemoryFrom:(uint16_t)start to:(uint16_t)end;

/// Write a byte into C64 memory.
- (void)writeByte:(uint8_t)value toAddress:(uint16_t)address;

/// Returns a disassembly string for the instruction at addr.
/// Format matches the VICE monitor style: "0810  A9 00     LDA #$00"
- (NSString *)disassembleAt:(uint16_t)address;

/// Disassemble `count` instructions starting at addr.
/// Returns an array of strings, one per instruction.
- (NSArray<NSString *> *)disassemble:(NSInteger)count
                    instructionsFrom:(uint16_t)address;

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — Breakpoints
// ─────────────────────────────────────────────────────────────

/// Set an execution breakpoint at the given address.
/// No-op if one already exists there.
- (void)setBreakpointAt:(uint16_t)address;

/// Remove the breakpoint at the given address.
- (void)deleteBreakpointAt:(uint16_t)address;

/// Remove all breakpoints.
- (void)deleteAllBreakpoints;

/// Returns YES if a breakpoint is set at addr.
- (BOOL)hasBreakpointAt:(uint16_t)address;

/// Set a memory watchpoint at the given address.
- (void)setWatchpointAt:(uint16_t)address;
- (void)deleteWatchpointAt:(uint16_t)address;
- (BOOL)hasWatchpointAt:(uint16_t)address;

// ─────────────────────────────────────────────────────────────
// MARK: RetroShell console
// ─────────────────────────────────────────────────────────────

/// Full text buffer of the currently-active RetroShell console.
/// Poll this after receiving VC64MessageRetroShellUpdate.
- (NSString *)retroShellText;

/// Feed a complete command string to RetroShell (async, queued).
- (void)retroShellExec:(NSString *)command;

/// Execute a RetroShell script file.
- (void)retroShellExecScript:(NSString *)path;

/// Switch to the commander console.
- (void)enterCommander;

/// Switch to the debugger console.
- (void)enterDebugger;

@end

NS_ASSUME_NONNULL_END
