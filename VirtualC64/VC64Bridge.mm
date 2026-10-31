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
// Internal header, for Memory::poke() in -writeByte:toAddress:.
#include "Memory.h"
// ────────────────────────────────────────────────────────────

#include <string>
#include <cmath>
#include <functional>
#include <ostream>
#include <streambuf>

// ─────────────────────────────────────────────────────────────
// MARK: - Failure helpers
// ─────────────────────────────────────────────────────────────

// VCCore reports failures by throwing, and since v6.2 every call that waits
// for the emulator thread also throws while that thread isn't running (not
// launched yet, or halted). An exception must never unwind through an
// Objective-C or Swift frame, so methods without an NSError out-parameter
// run such calls through here and log the failure instead.
template <typename F>
static void guarded(const char *what, F &&body)
{
    try {
        body();
    } catch (std::exception &e) {
        NSLog(@"VC64Bridge: %s failed: %s", what, e.what());
    }
}

// Sets an option and waits until it is in effect, so get() reads the new
// value straight away. v6.2's set() needs a running emulator thread; before
// launch the queued variant is used, which VCCore carries out at launch.
static void setOption(vc64::VirtualC64 *emu, vc64::Opt opt, int64_t value)
{
    guarded("set", [&]{
        if (emu->isLaunched()) emu->set(opt, value);
        else                   emu->setAsync(opt, value);
    });
}

// ─────────────────────────────────────────────────────────────
// MARK: - RetroShell output
// ─────────────────────────────────────────────────────────────

// RetroShell copies every finished console line, command echoes included,
// into an extra output stream (RetroShellAPI::setStream). This unbuffered
// stream buffer collects the characters of a line and hands each complete
// line to `sink`. RetroShell writes to it on the emulator thread.
class LineForwarder : public std::streambuf {
public:
    explicit LineForwarder(std::function<void(const std::string &)> sink)
    : sink(std::move(sink)) { }

protected:
    int_type overflow(int_type c) override
    {
        if (traits_type::eq_int_type(c, traits_type::eof())) return traits_type::not_eof(c);
        if (c == '\n') {
            sink(line);
            line.clear();
        } else {
            line.push_back(traits_type::to_char_type(c));
        }
        return c;
    }

private:
    std::function<void(const std::string &)> sink;
    std::string line;
};

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

    // ROMs are installed after the thread is launched (see -launch...), so
    // a launched emulator is not necessarily a ready one.
    BOOL            _romsLoaded;

    // The stream RetroShell copies its output into (see LineForwarder).
    // Created at launch; deleted after _emu, which still writes to it.
    LineForwarder   *_shellBuffer;
    std::ostream    *_shellStream;
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
        // Stop message delivery first, so a message posted during teardown
        // never reaches the listener pointer of an object that is going away.
        _emu->removeListener();
        // Halt the thread if still running
        if (_emu->isRunning() || _emu->isPaused()) {
            guarded("halt", [&]{ _emu->halt(); });
        }
        delete _emu;
        _emu = nullptr;
    }
    delete _shellStream;
    delete _shellBuffer;
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
        // Register the message callback. The listener pointer is bridged
        // to self via __bridge so ARC doesn't complain.
        __weak VC64Bridge *weakSelf = self;

        // A failed ROM load leaves the thread running, so a retry must not
        // launch it a second time (that throws ALREADY_LAUNCHED).
        if (!_emu->isLaunched()) {
            _emu->launch(
                (__bridge const void *)weakSelf,
                [](const void *ptr, vc64::Message msg, std::exception_ptr exception) {

                    // This callback fires on the emulator thread.
                    // Dispatch to main for all delegate calls.
                    VC64Bridge *bridge = (__bridge VC64Bridge *)ptr;
                    VC64Message mapped = mapMessage(msg.type);
                    uint16_t    data   = (uint16_t)(msg.value & 0xFFFF);

                    // A message can carry the failure of a queued request.
                    // Nothing in the IDE waits on those results; log them.
                    if (exception) {
                        try { std::rethrow_exception(exception); }
                        catch (std::exception &e) {
                            NSLog(@"VC64Bridge: emulator reported: %s", e.what());
                        }
                        catch (...) { }
                    }

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [bridge _handleMessage:mapped rawData:data];
                    });
                }
            );

            // Forward RetroShell's output, line by line, to the delegate.
            // The bridge is held weakly: a line still on its way to the main
            // queue when the bridge goes away is dropped.
            // The emulator thread has no autorelease pool of its own.
            _shellBuffer = new LineForwarder([weakSelf](const std::string &line) {
                @autoreleasepool {
                    NSString *text = [NSString stringWithUTF8String:line.c_str()] ?: @"";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        VC64Bridge *bridge = weakSelf;
                        id<VC64BridgeDelegate> d = bridge.delegate;
                        if ([d respondsToSelector:@selector(vc64:didPrintRetroShellLine:)]) {
                            [d vc64:bridge didPrintRetroShellLine:text];
                        }
                    });
                }
            });
            _shellStream = new std::ostream(_shellBuffer);
            _emu->retroShell.setStream(*_shellStream);
        }

        // NOTE: We do NOT install a separate polling NSTimer. The launch
        // callback above already dispatches each message to main as it's
        // produced. A second 60Hz pump was wasteful and risked saturating
        // the main runloop, making the host IDE feel unresponsive.

        // Install ROMs. Pass nil to use VirtualC64's built-in OpenROMs
        // (they're less accurate but handy for testing). Since v6.2 the ROM
        // calls run on the emulator thread, so they come after launch().
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
        _romsLoaded = YES;

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
                uint16_t jamPC = [self _currentCPUInfo].pc0;
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
    std::exception_ptr exception;
    while (_emu->c64.getMsg(msg, exception)) {
        VC64Message mapped = mapMessage(msg.type);
        [self _handleMessage:mapped rawData:(uint16_t)(msg.value & 0xFFFF)];
    }
}

- (BOOL)isReady    { return _emu->isLaunched() && _romsLoaded; }
- (BOOL)isPoweredOn{ return _emu->isPoweredOn(); }
- (BOOL)isRunning  { return _emu->isRunning();  }
- (BOOL)isPaused   { return _emu->isPaused();   }

// Since v6.2 the plain state calls wait for the emulator thread. The Async
// ones queue the request and return at once, as these did before v6.2.
- (void)powerOn    { _emu->powerOnAsync();  }
- (void)powerOff   { _emu->powerOffAsync(); }
- (void)hardReset  { _emu->hardResetAsync(); }
- (void)softReset  { _emu->softResetAsync(); }
- (void)halt       { guarded("halt", [&]{ _emu->halt(); }); }
- (void)wakeUp     { _emu->wakeUp(); }

// ─────────────────────────────────────────────────────────────
// MARK: Run Control
// ─────────────────────────────────────────────────────────────

// runAsync() still throws if a ROM is missing. Warp requests now name a
// source (0-6) and warp stays on while any source asks for it; the bridge
// is a single client, so it always uses source 0.
- (void)run     { guarded("run", [&]{ _emu->runAsync(); }); }
- (void)pause   { _emu->pauseAsync();    }
- (void)warpOn  { _emu->warpOnAsync(0);  }
- (void)warpOff { _emu->warpOffAsync(0); }

- (void)setWarpBootDuration:(NSInteger)seconds
{
    // C64_WARP_BOOT is a duration in EMULATED seconds. VCCore keeps the
    // machine in warp while cpu.clock < sec(warpBoot), then exits warp
    // automatically — see Emulator::computeFrame's warp check.
    if (!_emu) return;
    setOption(_emu, vc64::Opt::C64_WARP_BOOT, (int64_t)seconds);
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
        _emu->runAsync();
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
    guarded("ejectDisk", [&]{ drive.ejectDisk(); });
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
    // nr is the frame counter — we don't need it, pass a local.
    utl::isize nr = 0;
    const uint32_t *ptr = _emu->videoPort.getTexture(&nr);
    // The texture always has the fixed size vc64::Tex::width x height
    // (v6.2 dropped the size out-parameters).
    if (width)  *width  = ptr ? (NSInteger)vc64::Tex::width  : 0;
    if (height) *height = ptr ? (NSInteger)vc64::Tex::height : 0;
    return ptr;
}

- (nullable id<MTLTexture>)updateMetalTextureOnDevice:(id<MTLDevice>)device
{
    if (!_emu->isRunning() && !_emu->isPaused()) return nil;

    _emu->videoPort.lockTexture();

    utl::isize nr = 0;
    const uint32_t *src = _emu->videoPort.getTexture(&nr);
    NSInteger w = (NSInteger)vc64::Tex::width;
    NSInteger h = (NSInteger)vc64::Tex::height;

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
    setOption(_emu, vc64::Opt::HOST_SAMPLE_RATE, (int64_t)llround(hz));
}

// ─────────────────────────────────────────────────────────────
// MARK: Video standard
// ─────────────────────────────────────────────────────────────

- (void)setVideoStandard:(VC64Standard)standard
{
    if (!_emu) return;

    if (standard == VC64StandardNTSC) {
        setOption(_emu, vc64::Opt::VICII_REVISION,
                  (int64_t)vc64::VICIIRev::NTSC_6567);
        setOption(_emu, vc64::Opt::POWER_GRID,
                  (int64_t)vc64::PowerGrid::STABLE_60HZ);
    } else {
        setOption(_emu, vc64::Opt::VICII_REVISION,
                  (int64_t)vc64::VICIIRev::PAL_6569_R3);
        setOption(_emu, vc64::Opt::POWER_GRID,
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

// These throw if the emulator is already running.
- (void)stepInto    { guarded("stepInto",    [&]{ _emu->stepInto();    }); }
- (void)stepOver    { guarded("stepOver",    [&]{ _emu->stepOver();    }); }
- (void)stepCycle   { guarded("stepCycle",   [&]{ _emu->stepCycle();   }); }
- (void)finishLine  { guarded("finishLine",  [&]{ _emu->finishLine();  }); }
- (void)finishFrame { guarded("finishFrame", [&]{ _emu->finishFrame(); }); }

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — CPU / Memory inspection
// ─────────────────────────────────────────────────────────────

// The CPU state as it is now. getCachedInfo() is refreshed only while
// auto-inspection covers the CPU, which the IDE never switches on, so since
// v6.2 it keeps returning whatever the first read saw. getInfo() reads the
// live state; suspending the emulator thread around it makes the read
// consistent and lets a step that is still being carried out finish first.
- (vc64::CPUInfo)_currentCPUInfo
{
    vc64::CPUInfo info = {};
    _emu->suspend();
    info = _emu->cpu.getInfo();
    _emu->resume();
    return info;
}

- (VC64RegisterState)registers
{
    VC64RegisterState state = {};
    const vc64::CPUInfo info = [self _currentCPUInfo];
    state.pc    = info.pc;
    state.a     = info.a;
    state.x     = info.x;
    state.y     = info.y;
    state.sp    = info.sp;
    state.flags = info.sr;  // VCCore names the 6502 status register 'sr'
    return state;
}

// Reads `count` bytes from `start` on, as the CPU sees them and without side
// effects. VCCore's MemoryAPI doesn't expose a direct peek; the public read
// is the memory debugger's hexDump(), which formats a range read from one
// memory source (RAM/ROM/IO/Cartridge). The mapping can change every 4 KB,
// so the range is dumped page by page with the source MemInfo gives for that
// page, and the hex text is parsed back into bytes. As with the registers,
// the live MemInfo is read with the emulator suspended: the cached one is
// never refreshed and would miss bank switches.
- (void)_readBytes:(uint8_t *)out from:(uint16_t)start count:(NSUInteger)count
{
    _emu->suspend();
    const vc64::MemInfo info = _emu->mem.getInfo();
    NSUInteger done = 0;
    while (done < count) {
        uint16_t addr = (uint16_t)(start + done);
        NSUInteger chunk = MIN(count - done, (NSUInteger)(0x1000 - (addr & 0x0FFF)));
        std::string dump = _emu->mem.debugger.hexDump(info.peekSrc[addr >> 12],
                                                      addr, (utl::isize)chunk);
        // "A9 00 8D ...": two digits and a space per byte, "--" where
        // nothing is mapped (read as 0).
        for (NSUInteger i = 0; i < chunk; i++) {
            unsigned int val = 0;
            if (3 * i + 2 <= dump.size()) sscanf(dump.c_str() + 3 * i, "%2x", &val);
            out[done + i] = (uint8_t)val;
        }
        done += chunk;
    }
    _emu->resume();
}

- (uint8_t)readByte:(uint16_t)address
{
    uint8_t value = 0;
    [self _readBytes:&value from:address count:1];
    return value;
}

- (NSData *)readMemoryFrom:(uint16_t)start to:(uint16_t)end
{
    NSUInteger count = (end >= start) ? (NSUInteger)(end - start + 1) : 0;
    if (count == 0) return [NSData data];

    NSMutableData *data = [NSMutableData dataWithLength:count];
    [self _readBytes:(uint8_t *)data.mutableBytes from:start count:count];
    return data;
}

- (void)writeByte:(uint8_t)value toAddress:(uint16_t)address
{
    // VirtualC64 doesn't expose a memory write in the public API. RetroShell's
    // 'w' command is only known to the debugger console, which the shell
    // isn't in (entering it switches on track mode and prints into the
    // console), and the "m <addr> <value>" sent before only dumps memory.
    // 'w' calls Memory::poke(), so do the same on the emulator thread via
    // call(). The byte lands where a CPU write would: RAM, or the I/O
    // registers while they are banked in.
    guarded("writeByte", [&]{
        _emu->call([&]{ _emu->getMemory().poke(address, value); });
    });
}

- (NSString *)disassembleAt:(uint16_t)address
{
    // VCCore Peddle format chars: %p=PC, %b=instr bytes, %i=mnemonic.
    // NOTE: %x is the X register, not PC. The format string "%04p  %b  %i"
    // correctly outputs PC, instruction bytes, and mnemonic.
    std::string line = _emu->cpu.debugger.disassemble(address, "%04p  %b  %i");
    return @(line.c_str());
}

- (NSArray<NSString *> *)disassemble:(NSInteger)count
                   instructionsFrom:(uint16_t)address
{
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    uint16_t pc = address;

    for (NSInteger i = 0; i < count; i++) {
        utl::isize bytes = 0;
        std::string line = _emu->cpu.debugger.disassemble(pc, "%04p  %b  %i", &bytes);
        [result addObject:@(line.c_str())];
        // bytes is the instruction length — advance PC accordingly.
        if (bytes <= 0) bytes = 1;  // guard against malformed output
        pc += (uint16_t)bytes;
    }
    return result;
}

// ─────────────────────────────────────────────────────────────
// MARK: Debugger — Breakpoints
// ─────────────────────────────────────────────────────────────

// v6.2's GuardsAPI sets and removes guards by address and returns once the
// emulator thread has done it, so hasBreakpointAt: sees the change at once.
// It replaces the RetroShell commands used before ("break <addr>", "break
// delete"), which RetroShell rejected: it wants "break at <addr>" and a
// guard number for "delete".

- (void)setBreakpointAt:(uint16_t)address
{
    // Guard: if there's already a breakpoint there, don't add another.
    if ([self hasBreakpointAt:address]) return;
    guarded("setBreakpointAt", [&]{ _emu->cpu.breakpoints.setAt(address); });
}

- (void)deleteBreakpointAt:(uint16_t)address
{
    // removeAt() throws for an address without a breakpoint.
    if (![self hasBreakpointAt:address]) return;
    guarded("deleteBreakpointAt", [&]{ _emu->cpu.breakpoints.removeAt(address); });
}

- (void)deleteAllBreakpoints
{
    guarded("deleteAllBreakpoints", [&]{ _emu->cpu.breakpoints.removeAll(); });
}

- (BOOL)hasBreakpointAt:(uint16_t)address
{
    return _emu->cpu.breakpoints.guardAt(address).has_value();
}

- (NSArray<NSNumber *> *)breakpointAddresses
{
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    const vc64::GuardsAPI &breakpoints = _emu->cpu.breakpoints;
    for (utl::isize i = 0, n = breakpoints.elements(); i < n; i++) {
        if (auto info = breakpoints.guardNr(i)) [result addObject:@((uint16_t)info->addr)];
    }
    return result;
}

- (void)setWatchpointAt:(uint16_t)address
{
    if ([self hasWatchpointAt:address]) return;
    guarded("setWatchpointAt", [&]{ _emu->cpu.watchpoints.setAt(address); });
}

- (void)deleteWatchpointAt:(uint16_t)address
{
    if (![self hasWatchpointAt:address]) return;
    guarded("deleteWatchpointAt", [&]{ _emu->cpu.watchpoints.removeAt(address); });
}

- (BOOL)hasWatchpointAt:(uint16_t)address
{
    return _emu->cpu.watchpoints.guardAt(address).has_value();
}

// ─────────────────────────────────────────────────────────────
// MARK: RetroShell
// ─────────────────────────────────────────────────────────────

- (NSString *)retroShellText
{
    // text() now returns a copy and suspends the emulator while it makes it.
    std::string text;
    guarded("retroShellText", [&]{ text = _emu->retroShell.text(); });
    return [NSString stringWithUTF8String:text.c_str()] ?: @"";
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
    // Runs asynchronously; throws only if the file can't be opened.
    guarded("retroShellExecScript", [&]{
        _emu->retroShell.execScriptAsync(std::filesystem::path(path.UTF8String));
    });
}

- (void)enterCommander { _emu->retroShell.press(std::string("commander\n")); }
- (void)enterDebugger  { _emu->retroShell.press(std::string("debugger\n"));  }

@end

