// VC64Bridge.mm
// Objective-C++ implementation. This file must be compiled as ObjC++
// (.mm extension). Add it to your Xcode target and set
// "Compile Sources As" to "According to File Type" (the default).
//
// Add to your target's "Header Search Paths":
//   $(SRCROOT)/path/to/virtualc64/Emulator        (or wherever VirtualC64.h lives)
//
// Add the VirtualC64 static library (or XCFramework) to "Link Binary With Libraries".

#import "VC64Bridge.h"

// ── VirtualC64 C++ headers ──────────────────────────────────
// Adjust this path to match where you've placed the VC64 library headers.
#include "VirtualC64.h"
// ────────────────────────────────────────────────────────────

#include <string>
#include <cmath>

// ─────────────────────────────────────────────────────────────
// MARK: - Message mapping helper (C++ → ObjC enum)
// ─────────────────────────────────────────────────────────────

static VC64Message mapMessage(vc64::Msg m)
{
    // Map the vc64::Msg enum values we care about.
    // Verified against MsgQueueTypes.h in the cloned VCCore source.
    using M = vc64::Msg;
    switch (m) {
        // POWER fires for BOTH power-on (value=1) and power-off (value=0).
        // mapMessage has no access to the value, so it returns the On variant
        // as a placeholder; -_handleMessage:rawData: rewrites it to PowerOff
        // when the value is 0. Don't "fix" this here by reading the value —
        // the value isn't in scope at this layer.
        case M::POWER:              return VC64MessagePowerOn;
        case M::RUN:                return VC64MessageRun;
        case M::PAUSE:              return VC64MessagePause;
        case M::RESET:              return VC64MessageReset;
        // WARP, like POWER, fires for both edges (value=1 on, value=0 off).
        // Placeholder here; -_handleMessage:rawData: rewrites to WarpOff at value=0.
        case M::WARP:               return VC64MessageWarpOn;
        case M::BREAKPOINT_REACHED: return VC64MessageBreakpoint;
        case M::WATCHPOINT_REACHED: return VC64MessageWatchpoint;
        case M::CPU_JAMMED:         return VC64MessageCPUJammed;
        case M::RSH_WAIT:           return VC64MessageScriptPause;
        case M::RSH_UPDATE:         return VC64MessageRetroShellUpdate;
        case M::DISK_INSERT:        return VC64MessageDiskInserted;
        case M::DISK_EJECT:         return VC64MessageDiskEjected;
        default:                    return VC64MessageUnknown;
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Key mapping helper (Swift enum → C64Key)
// ─────────────────────────────────────────────────────────────

static vc64::C64Key mapKey(VC64KeyCode key)
{
    using K = vc64::C64Key;
    switch (key) {
        case VC64KeyDelete:          return K::del;
        case VC64KeyReturn:          return K::ret;
        case VC64KeyHome:            return K::home;
        case VC64KeyRunStop:         return K::runStop;
        case VC64KeyRestore:         return K::restore;
        case VC64KeySpace:           return K::space;
        case VC64KeyCursorLeftRight: return K::curLeftRight;
        case VC64KeyCursorUpDown:    return K::curUpDown;
        case VC64KeyF1F2:            return K::F1F2;
        case VC64KeyF3F4:            return K::F3F4;
        case VC64KeyF5F6:            return K::F5F6;
        case VC64KeyF7F8:            return K::F7F8;
        case VC64KeyLeftShift:       return K::leftShift;
        case VC64KeyRightShift:      return K::rightShift;
        case VC64KeyCommodore:       return K::commodore;
        case VC64KeyControl:         return K::control;
        case VC64KeyShiftLock:       return K::shiftLock;
    }
    // Unreachable for a well-formed enum, but keep the compiler happy and
    // fail safe to a harmless key rather than a default-constructed nr=0.
    return K::space;
}

// ─────────────────────────────────────────────────────────────
// MARK: - Private extension
// ─────────────────────────────────────────────────────────────

@interface VC64Bridge ()
{
    // The top-level VirtualC64 API object. Heap-allocated so we control
    // its lifetime explicitly (C++ objects with non-trivial dtors can't
    // be ivars directly in ARC ObjC++).
    vc64::VirtualC64 *_emu;

    // Cached Metal texture — recreated when dimensions change.
    id<MTLTexture>  _metalTexture;
    NSInteger       _metalTextureWidth;
    NSInteger       _metalTextureHeight;
}

// Pump the message queue and dispatch to delegate.
// Called on main thread from a polling timer after launch.
- (void)_pumpMessages;

@end

// ─────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────

@implementation VC64Bridge

- (instancetype)init
{
    if (!(self = [super init])) return nil;

    _emu = new vc64::VirtualC64();
    _metalTextureWidth  = 0;
    _metalTextureHeight = 0;

    return self;
}

- (void)dealloc
{
    if (_emu) {
        // Halt the thread if still running
        if (_emu->isRunning() || _emu->isPaused()) {
            _emu->halt();
        }
        delete _emu;
        _emu = nullptr;
    }
    [super dealloc];
}

// ─────────────────────────────────────────────────────────────
// MARK: Lifecycle
// ─────────────────────────────────────────────────────────────

- (BOOL)launchWithKernalROM:(NSString *)kernalROM
                   basicROM:(NSString *)basicROM
                    charROM:(NSString *)charROM
                      error:(NSError **)error
{
    try {
        // Install ROMs. Pass nil to use VirtualC64's built-in OpenROMs
        // (they're less accurate but handy for testing).
        if (kernalROM) {
            _emu->c64.loadRom(std::string(kernalROM.UTF8String));
        } else {
            _emu->c64.installOpenRoms();
        }
        if (basicROM) {
            _emu->c64.loadRom(std::string(basicROM.UTF8String));
        }
        if (charROM) {
            _emu->c64.loadRom(std::string(charROM.UTF8String));
        }

        // Register the message callback. The listener pointer is bridged
        // to self via __bridge so ARC doesn't complain.
        __weak VC64Bridge *weakSelf = self;

        _emu->launch(
            (__bridge const void *)weakSelf,
            [](const void *ptr, vc64::Message msg) {

                // This callback fires on the emulator thread.
                // Dispatch to main for all delegate calls.
                VC64Bridge *bridge = (__bridge VC64Bridge *)ptr;
                VC64Message mapped = mapMessage(msg.type);
                uint16_t    data   = (uint16_t)(msg.value & 0xFFFF);

                dispatch_async(dispatch_get_main_queue(), ^{
                    [bridge _handleMessage:mapped rawData:data];
                });
            }
        );

        // NOTE: We do NOT install a separate polling NSTimer. The launch
        // callback above already dispatches each message to main as it's
        // produced. A second 60Hz pump was wasteful and risked saturating
        // the main runloop, making the host IDE feel unresponsive.

        return YES;

    } catch (std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"VC64BridgeErrorDomain"
                                         code:-1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @(e.what())
            }];
        }
        return NO;
    }
}

- (void)_handleMessage:(VC64Message)msg rawData:(uint16_t)data
{
    // Dispatch specialised delegate callbacks for the messages Swift
    // is most likely to want individually.
    id<VC64BridgeDelegate> d = self.delegate;

    // mapMessage collapses both edges of Msg::POWER onto PowerOn because it
    // can't see the message value. Recover the real direction here: VCCore
    // sends value=1 for power-on, value=0 for power-off (C64::_powerOn/_powerOff).
    if (msg == VC64MessagePowerOn && data == 0) {
        msg = VC64MessagePowerOff;
    }
    if (msg == VC64MessageWarpOn && data == 0) {
        msg = VC64MessageWarpOff;
    }

    switch (msg) {
        case VC64MessageBreakpoint:
            if ([d respondsToSelector:@selector(vc64:didHitBreakpointAtPC:)]) {
                [d vc64:self didHitBreakpointAtPC:data];
            }
            break;
        case VC64MessageWatchpoint:
            if ([d respondsToSelector:@selector(vc64:didHitWatchpointAtPC:)]) {
                [d vc64:self didHitWatchpointAtPC:data];
            }
            break;
        case VC64MessageCPUJammed: {
            // CPU_JAMMED is emitted with NO payload (see C64.cpp — it's a
            // bare put(Msg::CPU_JAMMED)), so `data` is meaningless here. The
            // CPU has halted, though, so its register snapshot is stable;
            // pc0 holds the address the jammed instruction started at, which
            // is the address the IDE wants to surface.
            if ([d respondsToSelector:@selector(vc64:didJamAtPC:)]) {
                uint16_t jamPC = _emu->cpu.getCachedInfo().pc0;
                [d vc64:self didJamAtPC:jamPC];
            }
            break;
        }
        case VC64MessageRetroShellUpdate:
            if ([d respondsToSelector:@selector(vc64BridgeRetroShellDidUpdate:)]) {
                [d vc64BridgeRetroShellDidUpdate:self];
            }
            break;
        default:
            break;
    }

    // Always fire the generic callback too (also optional — guard it).
    if ([d respondsToSelector:@selector(vc64:didReceiveMessage:)]) {
        [d vc64:self didReceiveMessage:msg];
    }
}

- (void)_pumpMessages
{
    // Drain any messages that weren't caught by the launch callback.
    // (Shouldn't happen in practice, but good belt-and-suspenders.)
    vc64::Message msg;
    while (_emu->c64.getMsg(msg)) {
        VC64Message mapped = mapMessage(msg.type);
        [self _handleMessage:mapped rawData:(uint16_t)(msg.value & 0xFFFF)];
    }
}

- (BOOL)isReady    { return _emu->isLaunched(); }
- (BOOL)isPoweredOn{ return _emu->isPoweredOn(); }
- (BOOL)isRunning  { return _emu->isRunning();  }
- (BOOL)isPaused   { return _emu->isPaused();   }

- (void)powerOn    { _emu->powerOn();  }
- (void)powerOff   { _emu->powerOff(); }
- (void)hardReset  { _emu->hardReset(); }
- (void)softReset  { _emu->softReset(); }
- (void)halt       { _emu->halt(); }
- (void)wakeUp     { _emu->wakeUp(); }

// ─────────────────────────────────────────────────────────────
// MARK: Run Control
// ─────────────────────────────────────────────────────────────

- (void)run     { _emu->run();     }
- (void)pause   { _emu->pause();   }
- (void)warpOn  { _emu->warpOn();  }
- (void)warpOff { _emu->warpOff(); }

- (void)setWarpBootDuration:(NSInteger)seconds
{
    // C64_WARP_BOOT is a duration in EMULATED seconds. VCCore keeps the
    // machine in warp while cpu.clock < sec(warpBoot), then exits warp
    // automatically — see Emulator::computeFrame's warp check.
    if (!_emu) return;
    _emu->set(vc64::Opt::C64_WARP_BOOT, (int64_t)seconds);
}

- (NSInteger)warpBootDuration
{
    if (!_emu) return 0;
    return (NSInteger)_emu->get(vc64::Opt::C64_WARP_BOOT);
}

// ─────────────────────────────────────────────────────────────
// MARK: Media
// ─────────────────────────────────────────────────────────────

- (BOOL)flashPRG:(NSString *)path error:(NSError **)error
{
    try {
        _emu->c64.flash(std::filesystem::path(path.UTF8String));
        _emu->run();
        return YES;
    } catch (std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"VC64BridgeErrorDomain"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

- (BOOL)insertDisk:(NSString *)path
       driveNumber:(NSInteger)driveNumber
      writeProtect:(BOOL)writeProtect
             error:(NSError **)error
{
    try {
        vc64::DriveAPI &drive = (driveNumber == 9) ? _emu->drive9 : _emu->drive8;
        drive.insert(std::filesystem::path(path.UTF8String), writeProtect ? true : false);
        return YES;
    } catch (std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"VC64BridgeErrorDomain"
                                         code:-3
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

- (void)ejectDiskFromDrive:(NSInteger)driveNumber
{
    vc64::DriveAPI &drive = (driveNumber == 9) ? _emu->drive9 : _emu->drive8;
    drive.ejectDisk();
}

- (BOOL)saveDiskInDrive:(NSInteger)driveNumber
                 toPath:(NSString *)path
                  error:(NSError **)error
{
    try {
        vc64::DriveAPI &drive = (driveNumber == 9) ? _emu->drive9 : _emu->drive8;
        drive.save(std::filesystem::path(path.UTF8String));
        return YES;
    } catch (std::exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"VC64BridgeErrorDomain"
                                         code:-4
                                     userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
        }
        return NO;
    }
}

- (void)autoType:(NSString *)text
{
    _emu->keyboard.autoType(std::string(text.UTF8String));
}

// ─────────────────────────────────────────────────────────────
// MARK: Keyboard — discrete key events
// ─────────────────────────────────────────────────────────────

- (void)pressKey:(VC64KeyCode)key
{
    _emu->keyboard.press(mapKey(key));
}

- (void)releaseKey:(VC64KeyCode)key
{
    _emu->keyboard.release(mapKey(key));
}

- (void)toggleKey:(VC64KeyCode)key
{
    _emu->keyboard.toggle(mapKey(key));
}

- (void)releaseAllKeys
{
    _emu->keyboard.releaseAll();
}

- (BOOL)isKeyPressed:(VC64KeyCode)key
{
    return _emu->keyboard.isPressed(mapKey(key));
}

- (void)pressKey:(VC64KeyCode)key withModifier:(VC64KeyCode)modifier
{
    // The C64 scans its matrix at line rate, so a key pressed in the same
    // instant as its modifier can be read before the modifier lands. Press
    // the modifier now and schedule the key one frame (~0.02s) later, then
    // auto-release both via the `duration` argument so callers don't have to
    // track a release. 50ms down is comfortably longer than one scan.
    _emu->keyboard.press(mapKey(modifier), 0.0,  0.10);
    _emu->keyboard.press(mapKey(key),      0.02, 0.05);
}

- (void)pressCursorUp    { [self pressKey:VC64KeyCursorUpDown    withModifier:VC64KeyLeftShift]; }
- (void)pressCursorDown  { _emu->keyboard.press(mapKey(VC64KeyCursorUpDown),    0.0, 0.05); }
- (void)pressCursorLeft  { [self pressKey:VC64KeyCursorLeftRight withModifier:VC64KeyLeftShift]; }
- (void)pressCursorRight { _emu->keyboard.press(mapKey(VC64KeyCursorLeftRight), 0.0, 0.05); }

// ─────────────────────────────────────────────────────────────
// MARK: Video
// ─────────────────────────────────────────────────────────────

- (void)lockTexture   { _emu->videoPort.lockTexture();   }
- (void)unlockTexture { _emu->videoPort.unlockTexture(); }

- (nullable const uint32_t *)texturePointerWidth:(NSInteger *)width
                                          height:(NSInteger *)height
{
    utl::isize w = 0, h = 0;
    // nr is the frame counter — we don't need it, pass a local.
    utl::isize nr = 0;
    const uint32_t *ptr = _emu->videoPort.getTexture(&nr, &w, &h);
    if (width)  *width  = (NSInteger)w;
    if (height) *height = (NSInteger)h;
    return ptr;
}

- (nullable id<MTLTexture>)updateMetalTextureOnDevice:(id<MTLDevice>)device
{
    if (!_emu->isRunning() && !_emu->isPaused()) return nil;

    _emu->videoPort.lockTexture();

    NSInteger w = 0, h = 0;
    utl::isize nr = 0, cw = 0, ch = 0;
    const uint32_t *src = _emu->videoPort.getTexture(&nr, &cw, &ch);
    w = (NSInteger)cw;
    h = (NSInteger)ch;

    if (!src) {
        _emu->videoPort.unlockTexture();
        return nil;
    }

    // (Re)create the Metal texture if dimensions changed.
    if (!_metalTexture || _metalTextureWidth != w || _metalTextureHeight != h) {

        // VCCore writes u32 pixels in RGBA byte order. The MTKView in
        // VC64EmulatorWindowController is configured for .rgba8Unorm to
        // match. Keep these two pixel formats in sync — using BGRA on
        // either side swaps the R and B channels.
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:(NSUInteger)w
                                                              height:(NSUInteger)h
                                                           mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        _metalTexture       = [device newTextureWithDescriptor:desc];
        _metalTextureWidth  = w;
        _metalTextureHeight = h;
    }

    MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h);
    [_metalTexture replaceRegion:region
                     mipmapLevel:0
                       withBytes:src
                     bytesPerRow:(NSUInteger)w * 4];

    _emu->videoPort.unlockTexture();
    return _metalTexture;
}

- (BOOL)getVisibleAreaUMin:(double *)uMin
                      uMax:(double *)uMax
                      vMin:(double *)vMin
                      vMax:(double *)vMax
{
    // VCCore's findInnerAreaNormalized requires the emulator to be running
    // (it inspects the current texture to find non-border pixels). Calling
    // it before launch returns garbage.
    if (!_emu->isRunning() && !_emu->isPaused()) return NO;

    double x1 = 0, x2 = 1, y1 = 0, y2 = 1;
    _emu->videoPort.findInnerAreaNormalized(x1, x2, y1, y2);

    if (uMin) *uMin = x1;
    if (uMax) *uMax = x2;
    if (vMin) *vMin = y1;
    if (vMax) *vMax = y2;
    return YES;
}

// ─────────────────────────────────────────────────────────────
// MARK: Audio
// ─────────────────────────────────────────────────────────────

- (void)setHostSampleRate:(double)hz
{
    // HOST_SAMPLE_RATE lives on the Host component, but Emulator::set(Opt, i64)
    // forwards to the right component automatically. The value is the rate
    // VCCore should target when producing samples — we pass the host audio
    // engine's actual render rate (typically 44100 or 48000 Hz on macOS).
    //
    // Cast: VCCore's Opt setter takes i64 (signed long long). Hz is a double
    // because audio engines occasionally report fractional rates, but
    // HOST_SAMPLE_RATE is an integer option — round to the nearest Hz.
    if (!_emu) return;
    _emu->set(vc64::Opt::HOST_SAMPLE_RATE, (int64_t)llround(hz));
}

// ─────────────────────────────────────────────────────────────
// MARK: Video standard
// ─────────────────────────────────────────────────────────────

- (void)setVideoStandard:(VC64Standard)standard
{
    if (!_emu) return;

    if (standard == VC64StandardNTSC) {
        _emu->set(vc64::Opt::VICII_REVISION,
                  (int64_t)vc64::VICIIRev::NTSC_6567);
        _emu->set(vc64::Opt::POWER_GRID,
                  (int64_t)vc64::PowerGrid::STABLE_60HZ);
    } else {
        _emu->set(vc64::Opt::VICII_REVISION,
                  (int64_t)vc64::VICIIRev::PAL_6569_R3);
        _emu->set(vc64::Opt::POWER_GRID,
                  (int64_t)vc64::PowerGrid::STABLE_50HZ);
    }
}

- (VC64Standard)videoStandard
{
    if (!_emu) return VC64StandardPAL;

    switch ((vc64::VICIIRev)_emu->get(vc64::Opt::VICII_REVISION)) {
        case vc64::VICIIRev::NTSC_6567_R56A:
        case vc64::VICIIRev::NTSC_6567:
        case vc64::VICIIRev::NTSC_8562:
            return VC64StandardNTSC;
        default:
            return VC64StandardPAL;
    }
}

- (NSInteger)copyInterleavedSamples:(float *)buffer frames:(NSInteger)frames
{
    // Guard against being called before the bridge is launched. The audio
    // thread can race against bridge teardown on stop(); returning 0 makes
    // the source node emit silence, which is the right fallback.
    if (!_emu || !buffer || frames <= 0) return 0;
    if (!_emu->isRunning() && !_emu->isPaused()) return 0;

    // copyInterleaved returns isize (signed long). It can return fewer than
    // requested if the audio ring is starved; the caller is responsible for
    // zero-filling the remainder.
    return (NSInteger)_emu->audioPort.copyInterleaved(buffer, (long)frames);
}

- (NSInteger)copyStereoSamplesLeft:(float *)left
                              right:(float *)right
                             frames:(NSInteger)frames
{
    if (!_emu || !left || !right || frames <= 0) return 0;
    if (!_emu->isRunning() && !_emu->isPaused()) return 0;
    return (NSInteger)_emu->audioPort.copyStereo(left, right, (long)frames);
}

- (NSInteger)copyMonoSamples:(float *)buffer count:(NSInteger)count
{
    if (!_emu || !buffer || count <= 0) return 0;
    if (!_emu->isRunning() && !_emu->isPaused()) return 0;
    return (NSInteger)_emu->audioPort.copyMono(buffer, (long)count);
}

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — Execution control
// ─────────────────────────────────────────────────────────────

- (void)stepInto    { _emu->stepInto();    }
- (void)stepOver    { _emu->stepOver();    }
- (void)stepCycle   { _emu->stepCycle();   }
- (void)finishLine  { _emu->finishLine();  }
- (void)finishFrame { _emu->finishFrame(); }

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — CPU / Memory inspection
// ─────────────────────────────────────────────────────────────

- (VC64RegisterState)registers
{
    VC64RegisterState state = {};
    // getCachedInfo() is safe to call from any thread (reads a snapshot).
    const vc64::CPUInfo &info = _emu->cpu.getCachedInfo();
    state.pc    = info.pc;
    state.a     = info.a;
    state.x     = info.x;
    state.y     = info.y;
    state.sp    = info.sp;
    state.flags = info.sr;  // VCCore names the 6502 status register 'sr'
    return state;
}

- (uint8_t)readByte:(uint16_t)address
{
    // VCCore's MemoryAPI doesn't expose a direct peek; the only public read
    // mechanism is memdump() which returns a formatted string. Read the
    // current memory mapping (RAM/ROM/IO/Cartridge) for this address from
    // the cached MemInfo, then format/parse a single byte through memdump.
    //
    // NOTE: This is per-byte string formatting + sscanf. Fine for single
    // reads; awful in tight loops. For bulk reads, prefer -readMemoryFrom:to:
    // which still calls this in a loop, but at least batches via the same path.
    // A future optimization is to convince Dirk to expose Memory::spypeek()
    // on MemoryAPI, or to call memdump() once for a range and parse the
    // whole block.
    const vc64::MemInfo &info = _emu->mem.getCachedInfo();
    vc64::MemType src = info.peekSrc[address >> 12];
    std::string dump = _emu->mem.memdump(address, 1, true, 0, src);
    // The dump format is "XXXX: YY" — extract the hex byte.
    auto pos = dump.find(": ");
    if (pos == std::string::npos) return 0;
    unsigned int val = 0;
    sscanf(dump.c_str() + pos + 2, "%02x", &val);
    return (uint8_t)val;
}

- (NSData *)readMemoryFrom:(uint16_t)start to:(uint16_t)end
{
    NSUInteger count = (end >= start) ? (NSUInteger)(end - start + 1) : 0;
    if (count == 0) return [NSData data];

    NSMutableData *data = [NSMutableData dataWithLength:count];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;

    for (uint16_t addr = start; ; ++addr) {
        bytes[addr - start] = [self readByte:addr];
        if (addr == end) break;  // avoid wraparound on end == 0xFFFF
    }
    return data;
}

- (void)writeByte:(uint8_t)value toAddress:(uint16_t)address
{
    // VirtualC64 doesn't expose a direct mem.writeByte() in the public API,
    // so we go through RetroShell which is available and safe.
    // Alternative: call the non-public Memory::poke() if you link the full source.
    NSString *cmd = [NSString stringWithFormat:@"m %04X %02X", address, value];
    [self retroShellExec:cmd];
}

- (NSString *)disassembleAt:(uint16_t)address
{
    char buf[64] = {};
    // VCCore Peddle format chars: %p=PC, %b=instr bytes, %i=mnemonic.
    // NOTE: %x is the X register, not PC. The format string "%04p  %b  %i"
    // correctly outputs PC, instruction bytes, and mnemonic.
    _emu->cpu.disassemble(buf, "%04p  %b  %i", address);
    return @(buf);
}

- (NSArray<NSString *> *)disassemble:(NSInteger)count
                   instructionsFrom:(uint16_t)address
{
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    uint16_t pc = address;
    char buf[64] = {};

    for (NSInteger i = 0; i < count; i++) {
        utl::isize bytes = _emu->cpu.disassemble(buf, "%04p  %b  %i", pc);
        [result addObject:@(buf)];
        // bytes is the instruction length — advance PC accordingly.
        if (bytes <= 0) bytes = 1;  // guard against malformed output
        pc += (uint16_t)bytes;
    }
    return result;
}

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — Breakpoints
// ─────────────────────────────────────────────────────────────

- (void)setBreakpointAt:(uint16_t)address
{
    // Guard: if there's already a breakpoint there, don't add another.
    if (_emu->cpu.breakpointAt(address) != nullptr) return;
    // VirtualC64's public API reads breakpoints but doesn't expose
    // add/remove directly — go through RetroShell for set/delete.
    // The debugger console command is: "break <addr>"
    NSString *cmd = [NSString stringWithFormat:@"break %04X", address];
    [self retroShellExec:cmd];
}

- (void)deleteBreakpointAt:(uint16_t)address
{
    // Find the breakpoint's guard index, then delete by number.
    // The public API lets us query by address but not delete by address,
    // so we walk the numbered list.
    for (long i = 0; ; i++) {
        vc64::Guard *g = _emu->cpu.breakpointNr(i);
        if (!g) break;
        if (g->addr == (uint32_t)address) {
            NSString *cmd = [NSString stringWithFormat:@"break delete %ld", i];
            [self retroShellExec:cmd];
            break;
        }
    }
}

- (void)deleteAllBreakpoints
{
    [self retroShellExec:@"break delete"];
}

- (BOOL)hasBreakpointAt:(uint16_t)address
{
    return _emu->cpu.breakpointAt((uint32_t)address) != nullptr;
}

- (void)setWatchpointAt:(uint16_t)address
{
    if (_emu->cpu.watchpointAt(address) != nullptr) return;
    NSString *cmd = [NSString stringWithFormat:@"watch %04X", address];
    [self retroShellExec:cmd];
}

- (void)deleteWatchpointAt:(uint16_t)address
{
    for (long i = 0; ; i++) {
        vc64::Guard *g = _emu->cpu.watchpointNr(i);
        if (!g) break;
        if (g->addr == (uint32_t)address) {
            NSString *cmd = [NSString stringWithFormat:@"watch delete %ld", i];
            [self retroShellExec:cmd];
            break;
        }
    }
}

- (BOOL)hasWatchpointAt:(uint16_t)address
{
    return _emu->cpu.watchpointAt((uint32_t)address) != nullptr;
}

// ─────────────────────────────────────────────────────────────
// MARK: RetroShell
// ─────────────────────────────────────────────────────────────

- (NSString *)retroShellText
{
    const char *text = _emu->retroShell.text();
    return text ? @(text) : @"";
}

- (void)retroShellExec:(NSString *)command
{
    // VCCore's RetroShell takes typed input via press(). Append newline
    // to "submit" the line, matching what hitting Return would do.
    std::string cmd = std::string(command.UTF8String) + "\n";
    _emu->retroShell.press(cmd);
}

- (void)retroShellExecScript:(NSString *)path
{
    _emu->retroShell.execScript(std::filesystem::path(path.UTF8String));
}

- (void)enterCommander { _emu->retroShell.press(std::string("commander\n")); }
- (void)enterDebugger  { _emu->retroShell.press(std::string("debugger\n"));  }

@end

