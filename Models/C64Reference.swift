import Foundation

// MARK: - Memory Map Reference

/// Represents a single entry in the C64 memory map.
public struct MemoryMapEntry {
    public let address: UInt16
    public let endAddress: UInt16?
    public let name: String
    public let chip: C64Chip
    public let description: String
    public let bits: [BitFieldEntry]?

    /// Hexadecimal address range string (e.g., `$0400-$07E7` or `$D011`).
    public var addressString: String {
        if let end = endAddress {
            return String(format: "$%04X-$%04X", address, end)
        }
        return String(format: "$%04X", address)
    }

    /// Decimal address range string (e.g., `1024-2023` or `53265`).
    public var decimalString: String {
        if let end = endAddress {
            return "\(address)-\(end)"
        }
        return "\(address)"
    }
}

/// Represents a single bit or bit-field within a hardware register.
public struct BitFieldEntry {
    public let bits: String
    public let name: String
    public let description: String
}

/// Identifies the hardware component responsible for a memory region.
public enum C64Chip: String {
    case vic    = "VIC-II (6567/6569)"
    case sid    = "SID (6581/8580)"
    case cia1   = "CIA #1 (6526)"
    case cia2   = "CIA #2 (6526)"
    case cpu    = "CPU (6510)"
    case kernal = "KERNAL ROM"
    case basic  = "BASIC ROM"
    case ram    = "RAM"
    case io     = "I/O"
}

// MARK: - KERNAL Routine (expanded from PDF)

extension C64Reference {
    /// Describes a standard KERNAL routine with its entry point, signature, and behavior.
    public struct KernalRoutine {
        public let address: UInt16
        public let name: String
        public let description: String
        public let input: String?
        public let output: String?
        public let usedRegisters: String?
        public let realAddress: UInt16?
    }
}

// MARK: - C64 Color

extension C64Reference {
    /// Represents one of the 16 standard C64 VIC-II colors.
    public struct C64Color {
        public let index: Int
        public let name: String
        public let hex: String

        /// RGB components (0-255) derived from the hex string. Matches VICE's default palette.
        public var rgb: (r: Int, g: Int, b: Int) {
            guard hex.count >= 7 else { return (0, 0, 0) }
            let h = hex.dropFirst() // strip "#"
            let r = Int(h.prefix(2), radix: 16) ?? 0
            let g = Int(h.dropFirst(2).prefix(2), radix: 16) ?? 0
            let b = Int(h.dropFirst(4).prefix(2), radix: 16) ?? 0
            return (r, g, b)
        }
    }
}

// MARK: - C64 Reference Database

/// Static reference database for C64 hardware addresses, registers, KERNAL routines, and colors.
public struct C64Reference {

    // ══════════════════════════════════════════════════════════
    // MARK: - Zero Page ($0000-$00FF)
    // Source: sta.c64.org/cbm64mem.html (complete memory map PDF)
    // ══════════════════════════════════════════════════════════

    public static let zeroPageEntries: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0x0000, endAddress: nil, name: "CPU Data Direction Register", chip: .cpu,
            description: "6510 I/O port data direction. Bit = 1 means output. Default: $2F (%00101111).",
            bits: nil),
        MemoryMapEntry(address: 0x0001, endAddress: nil, name: "CPU I/O Port", chip: .cpu,
            description: "6510 I/O port. Controls ROM/RAM banking and Datasette. Default: $37 (%00110111).",
            bits: [
                BitFieldEntry(bits: "0", name: "LORAM", description: "BASIC ROM at $A000: 1=visible, 0=RAM"),
                BitFieldEntry(bits: "1", name: "HIRAM", description: "KERNAL ROM at $E000: 1=visible, 0=RAM"),
                BitFieldEntry(bits: "2", name: "CHAREN", description: "1=I/O at $D000, 0=Char ROM at $D000"),
                BitFieldEntry(bits: "3", name: "Datasette Out", description: "Datasette output signal level"),
                BitFieldEntry(bits: "4", name: "Datasette Btn", description: "0=Button pressed, 1=Not pressed"),
                BitFieldEntry(bits: "5", name: "Datasette Motor", description: "0=Motor on, 1=Motor off"),
            ]),
        MemoryMapEntry(address: 0x0003, endAddress: 0x0004, name: "Float→Int routine addr", chip: .ram,
            description: "Default: $B1AA, execution address of routine converting floating point to integer.", bits: nil),
        MemoryMapEntry(address: 0x0005, endAddress: 0x0006, name: "Int→Float routine addr", chip: .ram,
            description: "Default: $B391, execution address of routine converting integer to floating point.", bits: nil),
        MemoryMapEntry(address: 0x000A, endAddress: nil, name: "LOAD/VERIFY switch", chip: .ram,
            description: "$00=LOAD, $01-$FF=VERIFY.", bits: nil),
        MemoryMapEntry(address: 0x000D, endAddress: nil, name: "Expression type flag", chip: .ram,
            description: "Current expression type. $00=Numerical, $FF=String.", bits: nil),
        MemoryMapEntry(address: 0x000E, endAddress: nil, name: "Numeric type flag", chip: .ram,
            description: "Bit 7: 0=Floating point, 1=Integer.", bits: nil),
        MemoryMapEntry(address: 0x0011, endAddress: nil, name: "GET/INPUT/READ switch", chip: .ram,
            description: "$00=INPUT, $40=GET, $98=READ.", bits: nil),
        MemoryMapEntry(address: 0x0013, endAddress: nil, name: "Current I/O device", chip: .ram,
            description: "Default: $00 (keyboard input, screen output).", bits: nil),
        MemoryMapEntry(address: 0x0014, endAddress: 0x0015, name: "Line number / PEEK address", chip: .ram,
            description: "Line number during GOSUB/GOTO/RUN. Memory address during PEEK/POKE/SYS/WAIT.", bits: nil),
        MemoryMapEntry(address: 0x002B, endAddress: 0x002C, name: "Start of BASIC", chip: .ram,
            description: "Pointer to beginning of BASIC area. Default: $0801 (2049).", bits: nil),
        MemoryMapEntry(address: 0x002D, endAddress: 0x002E, name: "Start of variables", chip: .ram,
            description: "Pointer to beginning of variable area (end of program + 1).", bits: nil),
        MemoryMapEntry(address: 0x002F, endAddress: 0x0030, name: "Start of arrays", chip: .ram,
            description: "Pointer to beginning of array variable area.", bits: nil),
        MemoryMapEntry(address: 0x0031, endAddress: 0x0032, name: "End of arrays", chip: .ram,
            description: "Pointer to end of array variable area.", bits: nil),
        MemoryMapEntry(address: 0x0033, endAddress: 0x0034, name: "Start of strings", chip: .ram,
            description: "Pointer to beginning of string variable area (grows downwards).", bits: nil),
        MemoryMapEntry(address: 0x0037, endAddress: 0x0038, name: "End of BASIC", chip: .ram,
            description: "Pointer to end of BASIC area. Default: $A000 (40960).", bits: nil),
        MemoryMapEntry(address: 0x0039, endAddress: 0x003A, name: "Current BASIC line", chip: .ram,
            description: "$0000-$F9FF: Line number. $FF00-$FFFF: Direct mode.", bits: nil),
        MemoryMapEntry(address: 0x003B, endAddress: 0x003C, name: "CONT line number", chip: .ram,
            description: "Current BASIC line number for CONT.", bits: nil),
        MemoryMapEntry(address: 0x003D, endAddress: 0x003E, name: "CONT pointer", chip: .ram,
            description: "Pointer to next BASIC instruction for CONT. $0000-$00FF = can't CONT.", bits: nil),
        MemoryMapEntry(address: 0x003F, endAddress: 0x0040, name: "DATA line number", chip: .ram,
            description: "BASIC line number of current DATA item for READ.", bits: nil),
        MemoryMapEntry(address: 0x0041, endAddress: 0x0042, name: "DATA pointer", chip: .ram,
            description: "Pointer to next DATA item for READ.", bits: nil),
        MemoryMapEntry(address: 0x0061, endAddress: 0x0065, name: "FAC (register #1)", chip: .ram,
            description: "Floating-point Accumulator, arithmetic register #1 (5 bytes).", bits: nil),
        MemoryMapEntry(address: 0x0069, endAddress: 0x006D, name: "ARG (register #2)", chip: .ram,
            description: "Arithmetic register #2 (5 bytes).", bits: nil),
        MemoryMapEntry(address: 0x0073, endAddress: 0x008A, name: "CHRGET routine", chip: .ram,
            description: "Machine code routine to read next byte from BASIC program (24 bytes). Self-modifying: $7A-$7B is the current pointer.",
            bits: nil),
        MemoryMapEntry(address: 0x0090, endAddress: nil, name: "ST (Status variable)", chip: .ram,
            description: "Device status for serial bus/datasette. Bit 6: EOF. Bit 7: Device not present.",
            bits: [
                BitFieldEntry(bits: "0", name: "Direction", description: "Transfer direction at timeout: 0=Input, 1=Output"),
                BitFieldEntry(bits: "1", name: "Timeout", description: "1=Timeout occurred"),
                BitFieldEntry(bits: "4", name: "Verify error", description: "1=Verify error (VERIFY only)"),
                BitFieldEntry(bits: "6", name: "EOF", description: "1=End of file reached"),
                BitFieldEntry(bits: "7", name: "Not present", description: "1=Device not present"),
            ]),
        MemoryMapEntry(address: 0x0091, endAddress: nil, name: "Stop key indicator", chip: .ram,
            description: "$7F=Stop key pressed, $FF=Not pressed.", bits: nil),
        MemoryMapEntry(address: 0x0098, endAddress: nil, name: "Open file count", chip: .ram,
            description: "Number of files currently open. Values: $00-$0A (0-10).", bits: nil),
        MemoryMapEntry(address: 0x0099, endAddress: nil, name: "Current input device", chip: .ram,
            description: "Default: $00 (keyboard).", bits: nil),
        MemoryMapEntry(address: 0x009A, endAddress: nil, name: "Current output device", chip: .ram,
            description: "Default: $03 (screen).", bits: nil),
        MemoryMapEntry(address: 0x00A0, endAddress: 0x00A2, name: "TI (jiffy clock)", chip: .ram,
            description: "Time of day, incremented every 1/60 sec. 3 bytes: $00A0=high. Wraps at 5184000 (24 hrs on PAL).", bits: nil),
        MemoryMapEntry(address: 0x00C5, endAddress: nil, name: "Last key matrix code", chip: .ram,
            description: "$00-$3F: Keyboard matrix code. $40: No key pressed.", bits: nil),
        MemoryMapEntry(address: 0x00C6, endAddress: nil, name: "Keyboard buffer length", chip: .ram,
            description: "$00=Empty, $01-$0A=Buffer length.", bits: nil),
        MemoryMapEntry(address: 0x00C7, endAddress: nil, name: "Reverse mode", chip: .ram,
            description: "$00=Normal, $12=Reverse mode.", bits: nil),
        MemoryMapEntry(address: 0x00CB, endAddress: nil, name: "Current key matrix code", chip: .ram,
            description: "$00-$3F: Current key. $40: No key pressed.", bits: nil),
        MemoryMapEntry(address: 0x00CC, endAddress: nil, name: "Cursor visibility", chip: .ram,
            description: "$00=Cursor on, $01-$FF=Cursor off.", bits: nil),
        MemoryMapEntry(address: 0x00D1, endAddress: 0x00D2, name: "Screen line pointer", chip: .ram,
            description: "Pointer to current line in screen memory.", bits: nil),
        MemoryMapEntry(address: 0x00D3, endAddress: nil, name: "Cursor column", chip: .ram,
            description: "Current cursor column. Values: $00-$27 (0-39).", bits: nil),
        MemoryMapEntry(address: 0x00D6, endAddress: nil, name: "Cursor row", chip: .ram,
            description: "Current cursor row. Values: $00-$18 (0-24).", bits: nil),
        MemoryMapEntry(address: 0x00F3, endAddress: 0x00F4, name: "Color RAM pointer", chip: .ram,
            description: "Pointer to current line in Color RAM.", bits: nil),
        MemoryMapEntry(address: 0x00FB, endAddress: 0x00FE, name: "Free zero page", chip: .ram,
            description: "4 bytes of unused zero page — available for user programs.", bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - Stack & Buffers ($0100-$03FF)
    // ══════════════════════════════════════════════════════════

    public static let stackAndBufferEntries: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0x0100, endAddress: 0x01FF, name: "Processor Stack", chip: .ram,
            description: "256-byte hardware stack. Also used for FOR/GOSUB data storage. Stack pointer starts at $FF and grows downward.", bits: nil),
        MemoryMapEntry(address: 0x0200, endAddress: 0x0258, name: "Input Buffer", chip: .ram,
            description: "Storage area for data read from screen (89 bytes).", bits: nil),
        MemoryMapEntry(address: 0x0259, endAddress: 0x0262, name: "File logical numbers", chip: .ram,
            description: "Logical numbers assigned to open files (10 entries).", bits: nil),
        MemoryMapEntry(address: 0x0263, endAddress: 0x026C, name: "File device numbers", chip: .ram,
            description: "Device numbers assigned to open files (10 entries).", bits: nil),
        MemoryMapEntry(address: 0x026D, endAddress: 0x0276, name: "File secondary addrs", chip: .ram,
            description: "Secondary addresses assigned to open files (10 entries).", bits: nil),
        MemoryMapEntry(address: 0x0277, endAddress: 0x0280, name: "Keyboard Buffer", chip: .ram,
            description: "10-byte keyboard buffer. PETSCII codes of keys pressed.", bits: nil),
        MemoryMapEntry(address: 0x0281, endAddress: 0x0282, name: "BASIC start after test", chip: .ram,
            description: "Pointer to beginning of BASIC area after memory test. Default: $0800.", bits: nil),
        MemoryMapEntry(address: 0x0283, endAddress: 0x0284, name: "BASIC end after test", chip: .ram,
            description: "Pointer to end of BASIC area after memory test. Default: $A000.", bits: nil),
        MemoryMapEntry(address: 0x0286, endAddress: nil, name: "Current color", chip: .ram,
            description: "Cursor/text color. Values: $00-$0F (0-15). POKE 646,color.", bits: nil),
        MemoryMapEntry(address: 0x0288, endAddress: nil, name: "Screen memory page", chip: .ram,
            description: "High byte of screen memory pointer. Default: $04 → screen at $0400.", bits: nil),
        MemoryMapEntry(address: 0x0289, endAddress: nil, name: "Max keyboard buffer", chip: .ram,
            description: "Maximum keyboard buffer length. Default: $0A (10).", bits: nil),
        MemoryMapEntry(address: 0x028A, endAddress: nil, name: "Key repeat switch", chip: .ram,
            description: "Bits 6-7: %00=Only cursor/ins/del/space repeat, %01=No repeat, %1x=All keys repeat.", bits: nil),
        MemoryMapEntry(address: 0x028D, endAddress: nil, name: "Shift key status", chip: .ram,
            description: "Bit 0: Shift, Bit 1: Commodore key, Bit 2: Control key.",
            bits: [
                BitFieldEntry(bits: "0", name: "SHIFT", description: "1=Shift/Shift Lock pressed"),
                BitFieldEntry(bits: "1", name: "C=", description: "1=Commodore key pressed"),
                BitFieldEntry(bits: "2", name: "CTRL", description: "1=Control key pressed"),
            ]),
        MemoryMapEntry(address: 0x0291, endAddress: nil, name: "C=-Shift switch", chip: .ram,
            description: "Bit 7: 0=C=-Shift enabled (toggles charsets), 1=Disabled.", bits: nil),

        // BASIC/KERNAL vectors
        MemoryMapEntry(address: 0x0300, endAddress: 0x0301, name: "Warm reset vector", chip: .ram,
            description: "Error message routine and BASIC idle loop entry. Default: $E38B.", bits: nil),
        MemoryMapEntry(address: 0x0302, endAddress: 0x0303, name: "BASIC idle loop", chip: .ram,
            description: "Default: $A483.", bits: nil),
        MemoryMapEntry(address: 0x0304, endAddress: 0x0305, name: "Tokenizer vector", chip: .ram,
            description: "BASIC line tokenizer. Default: $A57C.", bits: nil),
        MemoryMapEntry(address: 0x0306, endAddress: 0x0307, name: "Token decoder vector", chip: .ram,
            description: "BASIC token decoder (LIST). Default: $A71A.", bits: nil),
        MemoryMapEntry(address: 0x0308, endAddress: 0x0309, name: "Executor vector", chip: .ram,
            description: "BASIC instruction executor. Default: $A7E4.", bits: nil),
        MemoryMapEntry(address: 0x030A, endAddress: 0x030B, name: "Expression eval vector", chip: .ram,
            description: "Read next BASIC expression item. Default: $AE86.", bits: nil),
        MemoryMapEntry(address: 0x030C, endAddress: nil, name: "SYS register A", chip: .ram,
            description: "Value of A register before/after SYS.", bits: nil),
        MemoryMapEntry(address: 0x030D, endAddress: nil, name: "SYS register X", chip: .ram,
            description: "Value of X register before/after SYS.", bits: nil),
        MemoryMapEntry(address: 0x030E, endAddress: nil, name: "SYS register Y", chip: .ram,
            description: "Value of Y register before/after SYS.", bits: nil),
        MemoryMapEntry(address: 0x030F, endAddress: nil, name: "SYS status register", chip: .ram,
            description: "Value of processor status register before/after SYS.", bits: nil),
        MemoryMapEntry(address: 0x0314, endAddress: 0x0315, name: "IRQ vector", chip: .ram,
            description: "Execution address of interrupt service routine. Default: $EA31.", bits: nil),
        MemoryMapEntry(address: 0x0316, endAddress: 0x0317, name: "BRK vector", chip: .ram,
            description: "Execution address of BRK handler. Default: $FE66.", bits: nil),
        MemoryMapEntry(address: 0x0318, endAddress: 0x0319, name: "NMI vector", chip: .ram,
            description: "Non-maskable interrupt handler. Default: $FE47.", bits: nil),
        MemoryMapEntry(address: 0x033C, endAddress: 0x03FB, name: "Datasette buffer", chip: .ram,
            description: "192-byte datasette buffer. Often used as free space for small ML routines.", bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - Screen Memory ($0400-$07FF)
    // ══════════════════════════════════════════════════════════

    public static let screenMemoryEntries: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0x0400, endAddress: 0x07E7, name: "Screen Memory", chip: .ram,
            description: "Default screen memory, 1000 bytes (40 columns × 25 rows). Each byte is a screen code (not PETSCII).", bits: nil),
        MemoryMapEntry(address: 0x07E8, endAddress: 0x07F7, name: "Unused", chip: .ram,
            description: "16 unused bytes between screen memory and sprite pointers.", bits: nil),
        MemoryMapEntry(address: 0x07F8, endAddress: 0x07FF, name: "Sprite Pointers", chip: .ram,
            description: "Default sprite data pointers (8 bytes). Pointer × 64 = sprite data address. E.g., pointer $0D → data at $0340.",
            bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - BASIC Area ($0800-$9FFF)
    // ══════════════════════════════════════════════════════════

    public static let basicAreaEntries: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0x0800, endAddress: nil, name: "BASIC area sentinel", chip: .ram,
            description: "Must contain 0 so BASIC program can be RUN.", bits: nil),
        MemoryMapEntry(address: 0x0801, endAddress: 0x9FFF, name: "BASIC Program Area", chip: .ram,
            description: "Default BASIC area (38911 bytes). Programs stored as tokenized linked list. Each line: 2-byte pointer to next line, 2-byte line number, tokenized data, $00 terminator.",
            bits: nil),
        MemoryMapEntry(address: 0x8000, endAddress: 0x9FFF, name: "Cartridge ROM (optional)", chip: .ram,
            description: "8KB optional cartridge ROM. $8000-$8001=cold reset addr, $8002-$8003=NMI addr, $8004-$8008=signature 'CBM80' ($C3,$C2,$CD,$38,$30).",
            bits: nil),
        MemoryMapEntry(address: 0xA000, endAddress: 0xBFFF, name: "BASIC ROM / RAM", chip: .basic,
            description: "8KB BASIC interpreter ROM. Banked via $0001 bits 0-2: %x11=BASIC ROM visible, otherwise RAM.", bits: nil),
        MemoryMapEntry(address: 0xC000, endAddress: 0xCFFF, name: "Upper RAM Area", chip: .ram,
            description: "4KB RAM always accessible. Popular location for ML routines — not affected by ROM banking.", bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - VIC-II Registers ($D000-$D3FF)
    // ══════════════════════════════════════════════════════════

    public static let vicRegisters: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0xD000, endAddress: 0xD00F, name: "Sprite X/Y Coordinates", chip: .vic,
            description: "Sprite positions. Even addresses ($D000,$D002...) = X low byte, odd = Y. Sprites 0-7.",
            bits: nil),
        MemoryMapEntry(address: 0xD010, endAddress: nil, name: "Sprites X MSB", chip: .vic,
            description: "Bit 8 of X coordinate for each sprite. Bit N = Sprite N.",
            bits: (0...7).map { BitFieldEntry(bits: "\($0)", name: "Spr \($0) X.8", description: "Sprite \($0) X-coordinate bit 8") }),
        MemoryMapEntry(address: 0xD011, endAddress: nil, name: "Screen Control #1", chip: .vic,
            description: "Vertical scroll, screen height, display enable, bitmap mode, ECM, raster bit 8. Default: $1B.",
            bits: [
                BitFieldEntry(bits: "0-2", name: "YSCROLL", description: "Vertical raster scroll (0-7)"),
                BitFieldEntry(bits: "3", name: "RSEL", description: "0=24 rows, 1=25 rows"),
                BitFieldEntry(bits: "4", name: "DEN", description: "Display enable: 0=off (border), 1=on"),
                BitFieldEntry(bits: "5", name: "BMM", description: "0=Text mode, 1=Bitmap mode"),
                BitFieldEntry(bits: "6", name: "ECM", description: "1=Extended background color mode"),
                BitFieldEntry(bits: "7", name: "RST8", description: "Read: raster line bit 8. Write: raster IRQ bit 8"),
            ]),
        MemoryMapEntry(address: 0xD012, endAddress: nil, name: "Raster Counter/Compare", chip: .vic,
            description: "Read: current raster line (bits 0-7). Write: raster line for IRQ trigger. Bit 8 in $D011 bit 7.", bits: nil),
        MemoryMapEntry(address: 0xD013, endAddress: nil, name: "Light Pen X", chip: .vic,
            description: "Light pen X-coordinate (bits 1-8). Read-only.", bits: nil),
        MemoryMapEntry(address: 0xD014, endAddress: nil, name: "Light Pen Y", chip: .vic,
            description: "Light pen Y-coordinate. Read-only.", bits: nil),
        MemoryMapEntry(address: 0xD015, endAddress: nil, name: "Sprite Enable", chip: .vic,
            description: "Each bit enables one sprite. Bit N = Sprite N.",
            bits: (0...7).map { BitFieldEntry(bits: "\($0)", name: "Spr \($0)", description: "1=Sprite \($0) enabled") }),
        MemoryMapEntry(address: 0xD016, endAddress: nil, name: "Screen Control #2", chip: .vic,
            description: "Horizontal scroll, screen width, multicolor. Default: $C8.",
            bits: [
                BitFieldEntry(bits: "0-2", name: "XSCROLL", description: "Horizontal raster scroll (0-7)"),
                BitFieldEntry(bits: "3", name: "CSEL", description: "0=38 columns, 1=40 columns"),
                BitFieldEntry(bits: "4", name: "MCM", description: "1=Multicolor mode on"),
            ]),
        MemoryMapEntry(address: 0xD017, endAddress: nil, name: "Sprite Double Height", chip: .vic,
            description: "Bit N: 1=Sprite N stretched to double height.", bits: nil),
        MemoryMapEntry(address: 0xD018, endAddress: nil, name: "Memory Setup", chip: .vic,
            description: "VIC-II memory pointers, relative to current VIC bank ($DD00).",
            bits: [
                BitFieldEntry(bits: "1-3", name: "CB", description: "Character/bitmap base addr (×$800). %010/%011 in bank 0/2 = Char ROM"),
                BitFieldEntry(bits: "4-7", name: "VM", description: "Screen memory base addr (×$400)"),
            ]),
        MemoryMapEntry(address: 0xD019, endAddress: nil, name: "Interrupt Status", chip: .vic,
            description: "Read: which IRQs occurred. Write 1 to acknowledge. Bit 7 = any IRQ pending.",
            bits: [
                BitFieldEntry(bits: "0", name: "Raster", description: "Raster line interrupt"),
                BitFieldEntry(bits: "1", name: "Spr-Bg", description: "Sprite-background collision"),
                BitFieldEntry(bits: "2", name: "Spr-Spr", description: "Sprite-sprite collision"),
                BitFieldEntry(bits: "3", name: "Light Pen", description: "Light pen triggered"),
                BitFieldEntry(bits: "7", name: "IRQ", description: "Any unacknowledged IRQ (read-only)"),
            ]),
        MemoryMapEntry(address: 0xD01A, endAddress: nil, name: "Interrupt Enable", chip: .vic,
            description: "Enable VIC-II interrupt sources. Set bit to 1 to enable.",
            bits: [
                BitFieldEntry(bits: "0", name: "Raster IRQ", description: "Enable raster interrupt"),
                BitFieldEntry(bits: "1", name: "Spr-Bg IRQ", description: "Enable sprite-background collision IRQ"),
                BitFieldEntry(bits: "2", name: "Spr-Spr IRQ", description: "Enable sprite-sprite collision IRQ"),
                BitFieldEntry(bits: "3", name: "LP IRQ", description: "Enable light pen IRQ"),
            ]),
        MemoryMapEntry(address: 0xD01B, endAddress: nil, name: "Sprite Priority", chip: .vic,
            description: "Bit N: 0=Sprite N in front of screen, 1=Behind screen.", bits: nil),
        MemoryMapEntry(address: 0xD01C, endAddress: nil, name: "Sprite Multicolor", chip: .vic,
            description: "Bit N: 0=Sprite N single-color, 1=Multicolor.", bits: nil),
        MemoryMapEntry(address: 0xD01D, endAddress: nil, name: "Sprite Double Width", chip: .vic,
            description: "Bit N: 1=Sprite N stretched to double width.", bits: nil),
        MemoryMapEntry(address: 0xD01E, endAddress: nil, name: "Sprite-Sprite Collision", chip: .vic,
            description: "Read: Bit N: 1=Sprite N collided with another sprite. Write to re-enable detection.", bits: nil),
        MemoryMapEntry(address: 0xD01F, endAddress: nil, name: "Sprite-Background Collision", chip: .vic,
            description: "Read: Bit N: 1=Sprite N collided with background. Write to re-enable.", bits: nil),
        MemoryMapEntry(address: 0xD020, endAddress: nil, name: "Border Color", chip: .vic,
            description: "Border color (bits 0-3). POKE 53280,color.", bits: nil),
        MemoryMapEntry(address: 0xD021, endAddress: nil, name: "Background Color 0", chip: .vic,
            description: "Main background color (bits 0-3). POKE 53281,color.", bits: nil),
        MemoryMapEntry(address: 0xD022, endAddress: nil, name: "Background Color 1", chip: .vic,
            description: "Extra background color 1 (multicolor/ECM).", bits: nil),
        MemoryMapEntry(address: 0xD023, endAddress: nil, name: "Background Color 2", chip: .vic,
            description: "Extra background color 2 (ECM).", bits: nil),
        MemoryMapEntry(address: 0xD024, endAddress: nil, name: "Background Color 3", chip: .vic,
            description: "Extra background color 3 (ECM).", bits: nil),
        MemoryMapEntry(address: 0xD025, endAddress: nil, name: "Sprite Extra Color 1", chip: .vic,
            description: "Shared multicolor sprite color 1 (bits 0-3).", bits: nil),
        MemoryMapEntry(address: 0xD026, endAddress: nil, name: "Sprite Extra Color 2", chip: .vic,
            description: "Shared multicolor sprite color 2 (bits 0-3).", bits: nil),
        MemoryMapEntry(address: 0xD027, endAddress: 0xD02E, name: "Sprite Colors 0-7", chip: .vic,
            description: "Individual sprite colors. $D027=Sprite 0 ... $D02E=Sprite 7.", bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - SID Registers ($D400-$D7FF)
    // ══════════════════════════════════════════════════════════

    public static let sidRegisters: [MemoryMapEntry] = [
        // Voice 1
        MemoryMapEntry(address: 0xD400, endAddress: 0xD401, name: "Voice 1 Frequency", chip: .sid,
            description: "16-bit frequency. Freq(Hz) = value × clock / 16777216. Clock: 985248 (PAL), 1022727 (NTSC). Write-only.", bits: nil),
        MemoryMapEntry(address: 0xD402, endAddress: 0xD403, name: "Voice 1 Pulse Width", chip: .sid,
            description: "12-bit pulse width (0-4095). Duty cycle = PW/40.95 %. 2048=50%. Write-only.", bits: nil),
        MemoryMapEntry(address: 0xD404, endAddress: nil, name: "Voice 1 Control", chip: .sid,
            description: "Waveform and gate control. Write-only.",
            bits: [
                BitFieldEntry(bits: "0", name: "GATE", description: "1=Start Attack-Decay-Sustain, 0=Start Release"),
                BitFieldEntry(bits: "1", name: "SYNC", description: "Synchronize with Voice 3"),
                BitFieldEntry(bits: "2", name: "RING", description: "Ring modulate with Voice 3"),
                BitFieldEntry(bits: "3", name: "TEST", description: "1=Disable oscillator, reset noise"),
                BitFieldEntry(bits: "4", name: "TRIANGLE", description: "Triangle waveform"),
                BitFieldEntry(bits: "5", name: "SAW", description: "Sawtooth waveform"),
                BitFieldEntry(bits: "6", name: "PULSE", description: "Pulse/rectangle waveform"),
                BitFieldEntry(bits: "7", name: "NOISE", description: "Noise waveform"),
            ]),
        MemoryMapEntry(address: 0xD405, endAddress: nil, name: "Voice 1 Attack/Decay", chip: .sid,
            description: "High nibble=Attack (2ms-8s), Low nibble=Decay (6ms-24s). Write-only.",
            bits: [
                BitFieldEntry(bits: "0-3", name: "Decay", description: "0:6ms 1:24ms 2:48ms 3:72ms 4:114ms 5:168ms 6:204ms 7:240ms 8:300ms 9:750ms A:1.5s B:2.4s C:3s D:9s E:15s F:24s"),
                BitFieldEntry(bits: "4-7", name: "Attack", description: "0:2ms 1:8ms 2:16ms 3:24ms 4:38ms 5:56ms 6:68ms 7:80ms 8:100ms 9:250ms A:500ms B:800ms C:1s D:3s E:5s F:8s"),
            ]),
        MemoryMapEntry(address: 0xD406, endAddress: nil, name: "Voice 1 Sustain/Release", chip: .sid,
            description: "High nibble=Sustain level (0-15), Low nibble=Release rate (same as Decay). Write-only.",
            bits: [
                BitFieldEntry(bits: "0-3", name: "Release", description: "Same rates as Decay"),
                BitFieldEntry(bits: "4-7", name: "Sustain", description: "Sustain volume level (0=silent, 15=max)"),
            ]),
        // Voice 2 & 3 follow same structure
        MemoryMapEntry(address: 0xD407, endAddress: 0xD40D, name: "Voice 2 Registers", chip: .sid,
            description: "Voice 2: Same structure as Voice 1 ($D407-$D408=Freq, $D409-$D40A=PW, $D40B=Ctrl, $D40C=AD, $D40D=SR). Write-only.", bits: nil),
        MemoryMapEntry(address: 0xD40E, endAddress: 0xD414, name: "Voice 3 Registers", chip: .sid,
            description: "Voice 3: Same structure ($D40E-$D40F=Freq, $D410-$D411=PW, $D412=Ctrl, $D413=AD, $D414=SR). Write-only.", bits: nil),
        // Filter & Volume
        MemoryMapEntry(address: 0xD415, endAddress: 0xD416, name: "Filter Cutoff", chip: .sid,
            description: "$D415 bits 0-2 = low 3 bits, $D416 = high 8 bits (11-bit total). Write-only.", bits: nil),
        MemoryMapEntry(address: 0xD417, endAddress: nil, name: "Filter Control", chip: .sid,
            description: "Voice routing and resonance. Write-only.",
            bits: [
                BitFieldEntry(bits: "0", name: "FILT1", description: "Route Voice 1 through filter"),
                BitFieldEntry(bits: "1", name: "FILT2", description: "Route Voice 2 through filter"),
                BitFieldEntry(bits: "2", name: "FILT3", description: "Route Voice 3 through filter"),
                BitFieldEntry(bits: "3", name: "FILTEX", description: "Route external audio through filter"),
                BitFieldEntry(bits: "4-7", name: "RES", description: "Filter resonance (0-15)"),
            ]),
        MemoryMapEntry(address: 0xD418, endAddress: nil, name: "Volume / Filter Mode", chip: .sid,
            description: "Master volume and filter type. Write-only.",
            bits: [
                BitFieldEntry(bits: "0-3", name: "VOL", description: "Master volume (0-15)"),
                BitFieldEntry(bits: "4", name: "LP", description: "Low-pass filter"),
                BitFieldEntry(bits: "5", name: "BP", description: "Band-pass filter"),
                BitFieldEntry(bits: "6", name: "HP", description: "High-pass filter"),
                BitFieldEntry(bits: "7", name: "3OFF", description: "Disconnect Voice 3 output"),
            ]),
        MemoryMapEntry(address: 0xD419, endAddress: nil, name: "Paddle X", chip: .sid,
            description: "Paddle X value (selected via $DC00). Updates every 512 cycles. Read-only.", bits: nil),
        MemoryMapEntry(address: 0xD41A, endAddress: nil, name: "Paddle Y", chip: .sid,
            description: "Paddle Y value. Read-only.", bits: nil),
        MemoryMapEntry(address: 0xD41B, endAddress: nil, name: "Voice 3 Waveform Output", chip: .sid,
            description: "Current output of Voice 3 oscillator. Read-only. Useful for random numbers (set Voice 3 to noise).", bits: nil),
        MemoryMapEntry(address: 0xD41C, endAddress: nil, name: "Voice 3 ADSR Output", chip: .sid,
            description: "Current Voice 3 envelope output. Read-only.", bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - Color RAM ($D800-$DBFF)
    // ══════════════════════════════════════════════════════════

    public static let colorRAMEntries: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0xD800, endAddress: 0xDBE7, name: "Color RAM", chip: .ram,
            description: "1000 nybbles (bits 0-3 only) of color data for each screen character. Always at this address regardless of VIC bank. POKE 55296+offset,color.",
            bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - CIA #1 ($DC00-$DCFF)
    // ══════════════════════════════════════════════════════════

    public static let cia1Registers: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0xDC00, endAddress: nil, name: "CIA1 Port A", chip: .cia1,
            description: "Keyboard matrix columns (write) and Joystick #2 (read).",
            bits: [
                BitFieldEntry(bits: "0", name: "Joy2 Up / Col 0", description: "Read: 0=Joystick 2 up. Write: select keyboard column 0"),
                BitFieldEntry(bits: "1", name: "Joy2 Down / Col 1", description: "Joystick 2 down / column 1"),
                BitFieldEntry(bits: "2", name: "Joy2 Left / Col 2", description: "Joystick 2 left / column 2"),
                BitFieldEntry(bits: "3", name: "Joy2 Right / Col 3", description: "Joystick 2 right / column 3"),
                BitFieldEntry(bits: "4", name: "Joy2 Fire / Col 4", description: "Joystick 2 fire / column 4"),
                BitFieldEntry(bits: "6-7", name: "Paddle select", description: "%01=Paddle 1, %10=Paddle 2"),
            ]),
        MemoryMapEntry(address: 0xDC01, endAddress: nil, name: "CIA1 Port B", chip: .cia1,
            description: "Keyboard matrix rows (read) and Joystick #1 (read).",
            bits: [
                BitFieldEntry(bits: "0", name: "Joy1 Up / Row 0", description: "0=Key pressed in row 0 or joystick up"),
                BitFieldEntry(bits: "1", name: "Joy1 Down / Row 1", description: "0=Row 1 key or joystick down"),
                BitFieldEntry(bits: "2", name: "Joy1 Left / Row 2", description: "0=Row 2 key or joystick left"),
                BitFieldEntry(bits: "3", name: "Joy1 Right / Row 3", description: "0=Row 3 key or joystick right"),
                BitFieldEntry(bits: "4", name: "Joy1 Fire / Row 4", description: "0=Row 4 key or joystick fire"),
            ]),
        MemoryMapEntry(address: 0xDC02, endAddress: nil, name: "CIA1 Port A DDR", chip: .cia1,
            description: "Data direction for Port A. Bit=0: input, Bit=1: output.", bits: nil),
        MemoryMapEntry(address: 0xDC03, endAddress: nil, name: "CIA1 Port B DDR", chip: .cia1,
            description: "Data direction for Port B.", bits: nil),
        MemoryMapEntry(address: 0xDC04, endAddress: 0xDC05, name: "CIA1 Timer A", chip: .cia1,
            description: "Read: current timer value. Write: set start value. 16-bit countdown timer.", bits: nil),
        MemoryMapEntry(address: 0xDC06, endAddress: 0xDC07, name: "CIA1 Timer B", chip: .cia1,
            description: "Read: current timer value. Write: set start value.", bits: nil),
        MemoryMapEntry(address: 0xDC08, endAddress: 0xDC0B, name: "CIA1 Time of Day", chip: .cia1,
            description: "$DC08=1/10 sec, $DC09=sec, $DC0A=min, $DC0B=hours (all BCD). Read=TOD, Write=set TOD or alarm.",
            bits: nil),
        MemoryMapEntry(address: 0xDC0D, endAddress: nil, name: "CIA1 Interrupt Control", chip: .cia1,
            description: "Read: occurred IRQs. Write: enable/disable. Bit 7 read=IRQ active, write=fill bit.",
            bits: [
                BitFieldEntry(bits: "0", name: "Timer A", description: "Timer A underflow"),
                BitFieldEntry(bits: "1", name: "Timer B", description: "Timer B underflow"),
                BitFieldEntry(bits: "2", name: "TOD Alarm", description: "TOD equals alarm time"),
                BitFieldEntry(bits: "3", name: "Serial", description: "Serial shift register byte complete"),
                BitFieldEntry(bits: "4", name: "FLAG", description: "Signal on FLAG pin (datasette)"),
                BitFieldEntry(bits: "7", name: "IRQ/Fill", description: "Read: IRQ occurred. Write: fill bit for enables"),
            ]),
        MemoryMapEntry(address: 0xDC0E, endAddress: nil, name: "CIA1 Timer A Control", chip: .cia1,
            description: "Timer A configuration.",
            bits: [
                BitFieldEntry(bits: "0", name: "START", description: "0=Stop, 1=Start timer"),
                BitFieldEntry(bits: "1", name: "PBON", description: "1=Timer output on Port B bit 6"),
                BitFieldEntry(bits: "2", name: "OUTMODE", description: "0=Toggle, 1=Pulse on underflow"),
                BitFieldEntry(bits: "3", name: "RUNMODE", description: "0=Continuous, 1=One-shot"),
                BitFieldEntry(bits: "4", name: "LOAD", description: "1=Force-load start value"),
                BitFieldEntry(bits: "5", name: "INMODE", description: "0=Count φ2 cycles, 1=Count CNT edges"),
                BitFieldEntry(bits: "6", name: "SPMODE", description: "Serial port: 0=Input, 1=Output"),
                BitFieldEntry(bits: "7", name: "TODIN", description: "TOD clock: 0=60Hz, 1=50Hz"),
            ]),
        MemoryMapEntry(address: 0xDC0F, endAddress: nil, name: "CIA1 Timer B Control", chip: .cia1,
            description: "Timer B configuration. Bits 5-6: %00=φ2, %01=CNT, %10=Timer A underflow, %11=Timer A + CNT.",
            bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - CIA #2 ($DD00-$DDFF)
    // ══════════════════════════════════════════════════════════

    public static let cia2Registers: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0xDD00, endAddress: nil, name: "CIA2 Port A", chip: .cia2,
            description: "VIC bank selection, serial bus, RS232 TXD.",
            bits: [
                BitFieldEntry(bits: "0-1", name: "VIC Bank", description: "%00=Bank 3 ($C000), %01=Bank 2 ($8000), %10=Bank 1 ($4000), %11=Bank 0 ($0000)"),
                BitFieldEntry(bits: "2", name: "RS232 TXD", description: "RS232 output bit"),
                BitFieldEntry(bits: "3", name: "ATN OUT", description: "Serial bus ATN: 0=High, 1=Low"),
                BitFieldEntry(bits: "4", name: "CLK OUT", description: "Serial bus CLOCK: 0=High, 1=Low"),
                BitFieldEntry(bits: "5", name: "DATA OUT", description: "Serial bus DATA: 0=High, 1=Low"),
                BitFieldEntry(bits: "6", name: "CLK IN", description: "Serial bus CLOCK input"),
                BitFieldEntry(bits: "7", name: "DATA IN", description: "Serial bus DATA input"),
            ]),
        MemoryMapEntry(address: 0xDD01, endAddress: nil, name: "CIA2 Port B", chip: .cia2,
            description: "RS232 lines and user port. Read: RXD, RI, DCD, CTS, DSR. Write: RTS, DTR.", bits: nil),
        MemoryMapEntry(address: 0xDD02, endAddress: nil, name: "CIA2 Port A DDR", chip: .cia2,
            description: "Data direction for Port A. Default: $03 (bits 0-1 output for VIC bank).", bits: nil),
        MemoryMapEntry(address: 0xDD04, endAddress: 0xDD05, name: "CIA2 Timer A", chip: .cia2,
            description: "Timer A. Read: current value. Write: start value.", bits: nil),
        MemoryMapEntry(address: 0xDD06, endAddress: 0xDD07, name: "CIA2 Timer B", chip: .cia2,
            description: "Timer B. Read: current value. Write: start value.", bits: nil),
        MemoryMapEntry(address: 0xDD08, endAddress: 0xDD0B, name: "CIA2 Time of Day", chip: .cia2,
            description: "TOD clock (BCD). Same layout as CIA1 TOD.", bits: nil),
        MemoryMapEntry(address: 0xDD0D, endAddress: nil, name: "CIA2 NMI Control", chip: .cia2,
            description: "Same as CIA1 $DC0D but generates NMI instead of IRQ.",
            bits: [
                BitFieldEntry(bits: "0", name: "Timer A", description: "Timer A underflow → NMI"),
                BitFieldEntry(bits: "1", name: "Timer B", description: "Timer B underflow → NMI"),
                BitFieldEntry(bits: "2", name: "TOD Alarm", description: "TOD alarm → NMI"),
                BitFieldEntry(bits: "3", name: "Serial", description: "Serial shift register → NMI"),
                BitFieldEntry(bits: "4", name: "FLAG", description: "FLAG pin → NMI"),
                BitFieldEntry(bits: "7", name: "NMI/Fill", description: "Read: NMI occurred. Write: fill bit"),
            ]),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - KERNAL Area & Hardware Vectors ($E000-$FFFF)
    // ══════════════════════════════════════════════════════════

    public static let kernalAreaEntries: [MemoryMapEntry] = [
        MemoryMapEntry(address: 0xE000, endAddress: 0xFFFF, name: "KERNAL ROM / RAM", chip: .kernal,
            description: "8KB KERNAL ROM. Banked via $0001: bit 1 = 1 → KERNAL visible, 0 → RAM.", bits: nil),
        MemoryMapEntry(address: 0xFFFA, endAddress: 0xFFFB, name: "NMI Vector (hardware)", chip: .kernal,
            description: "Hardware NMI vector. Default: $FE43.", bits: nil),
        MemoryMapEntry(address: 0xFFFC, endAddress: 0xFFFD, name: "RESET Vector (hardware)", chip: .kernal,
            description: "Hardware reset vector. Default: $FCE2.", bits: nil),
        MemoryMapEntry(address: 0xFFFE, endAddress: 0xFFFF, name: "IRQ Vector (hardware)", chip: .kernal,
            description: "Hardware IRQ/BRK vector. Default: $FF48.", bits: nil),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - KERNAL Routines (from KERNAL functions PDF)
    // ══════════════════════════════════════════════════════════

    public static let kernalRoutines: [KernalRoutine] = [
        KernalRoutine(address: 0xFF81, name: "SCINIT", description: "Initialize VIC; restore default I/O to keyboard/screen; clear screen; set PAL/NTSC switch and interrupt timer.", input: nil, output: nil, usedRegisters: "A, X, Y", realAddress: 0xFF5B),
        KernalRoutine(address: 0xFF84, name: "IOINIT", description: "Initialize CIAs, SID volume; setup memory configuration; set and start interrupt timer.", input: nil, output: nil, usedRegisters: "A, X", realAddress: 0xFDA3),
        KernalRoutine(address: 0xFF87, name: "RAMTAS", description: "Clear $0002-$0101 and $0200-$03FF; run memory test; set BASIC start/end; set screen memory to $0400 and datasette buffer to $033C.", input: nil, output: nil, usedRegisters: "A, X, Y", realAddress: 0xFD50),
        KernalRoutine(address: 0xFF8A, name: "RESTOR", description: "Fill vector table at $0314-$0333 with default values.", input: nil, output: nil, usedRegisters: "—", realAddress: 0xFD15),
        KernalRoutine(address: 0xFF8D, name: "VECTOR", description: "Copy vector table at $0314-$0333 from or into user table.", input: "Carry: 0=Copy user→vectors, 1=Copy vectors→user; X/Y=Pointer to user table", output: nil, usedRegisters: "A, Y", realAddress: 0xFD1A),
        KernalRoutine(address: 0xFF90, name: "SETMSG", description: "Set system error display switch at $009D.", input: "A=Switch value", output: nil, usedRegisters: "—", realAddress: 0xFE18),
        KernalRoutine(address: 0xFF93, name: "LSTNSA", description: "Send LISTEN secondary address to serial bus. Must call LISTEN first.", input: "A=Secondary address", output: nil, usedRegisters: "A", realAddress: 0xEDB9),
        KernalRoutine(address: 0xFF96, name: "TALKSA", description: "Send TALK secondary address to serial bus. Must call TALK first.", input: "A=Secondary address", output: nil, usedRegisters: "A", realAddress: 0xEDC7),
        KernalRoutine(address: 0xFF99, name: "MEMBOT", description: "Save or restore start address of BASIC work area.", input: "Carry: 0=Restore from X/Y, 1=Save to X/Y", output: "X/Y=Address (if Carry=1)", usedRegisters: "X, Y", realAddress: 0xFE25),
        KernalRoutine(address: 0xFF9C, name: "MEMTOP", description: "Save or restore end address of BASIC work area.", input: "Carry: 0=Restore from X/Y, 1=Save to X/Y", output: "X/Y=Address (if Carry=1)", usedRegisters: "X, Y", realAddress: 0xFE34),
        KernalRoutine(address: 0xFF9F, name: "SCNKEY", description: "Query keyboard; put current matrix code into $00CB, shift key status into $028D, PETSCII code into keyboard buffer.", input: nil, output: nil, usedRegisters: "A, X, Y", realAddress: 0xEA87),
        KernalRoutine(address: 0xFFA2, name: "SETTMO", description: "Set serial bus timeout.", input: "A=Timeout value", output: nil, usedRegisters: "—", realAddress: 0xFE21),
        KernalRoutine(address: 0xFFA5, name: "IECIN", description: "Read byte from serial bus. Must call TALK and TALKSA first.", input: nil, output: "A=Byte read", usedRegisters: "A", realAddress: 0xEE13),
        KernalRoutine(address: 0xFFA8, name: "IECOUT", description: "Write byte to serial bus. Must call LISTEN and LSTNSA first.", input: "A=Byte to write", output: nil, usedRegisters: "—", realAddress: 0xEDDD),
        KernalRoutine(address: 0xFFAB, name: "UNTALK", description: "Send UNTALK command to serial bus.", input: nil, output: nil, usedRegisters: "A", realAddress: 0xEDEF),
        KernalRoutine(address: 0xFFAE, name: "UNLSTN", description: "Send UNLISTEN command to serial bus.", input: nil, output: nil, usedRegisters: "A", realAddress: 0xEDFE),
        KernalRoutine(address: 0xFFB1, name: "LISTEN", description: "Send LISTEN command to serial bus.", input: "A=Device number", output: nil, usedRegisters: "A", realAddress: 0xED0C),
        KernalRoutine(address: 0xFFB4, name: "TALK", description: "Send TALK command to serial bus.", input: "A=Device number", output: nil, usedRegisters: "A", realAddress: 0xED09),
        KernalRoutine(address: 0xFFB7, name: "READST", description: "Fetch status of current I/O device (ST variable). RS232 status is cleared after reading.", input: nil, output: "A=Device status", usedRegisters: "A", realAddress: 0xFE07),
        KernalRoutine(address: 0xFFBA, name: "SETLFS", description: "Set file parameters for OPEN.", input: "A=Logical number, X=Device number, Y=Secondary address", output: nil, usedRegisters: "—", realAddress: 0xFE00),
        KernalRoutine(address: 0xFFBD, name: "SETNAM", description: "Set file name parameters.", input: "A=Name length, X/Y=Pointer to name (lo/hi)", output: nil, usedRegisters: "—", realAddress: 0xFDF9),
        KernalRoutine(address: 0xFFC0, name: "OPEN", description: "Open a logical file. Must call SETLFS and SETNAM first.", input: nil, output: nil, usedRegisters: "A, X, Y", realAddress: 0xF34A),
        KernalRoutine(address: 0xFFC3, name: "CLOSE", description: "Close a logical file.", input: "A=Logical number", output: nil, usedRegisters: "A, X, Y", realAddress: 0xF291),
        KernalRoutine(address: 0xFFC6, name: "CHKIN", description: "Define file as default input. Must call OPEN first.", input: "X=Logical number", output: nil, usedRegisters: "A, X", realAddress: 0xF20E),
        KernalRoutine(address: 0xFFC9, name: "CHKOUT", description: "Define file as default output. Must call OPEN first.", input: "X=Logical number", output: nil, usedRegisters: "A, X", realAddress: 0xF250),
        KernalRoutine(address: 0xFFCC, name: "CLRCHN", description: "Close default I/O files; restore default I/O to keyboard/screen. Sends UNTALK/UNLISTEN on serial bus.", input: nil, output: nil, usedRegisters: "A, X", realAddress: 0xF333),
        KernalRoutine(address: 0xFFCF, name: "CHRIN", description: "Read byte from default input (keyboard: reads line from screen). Must call OPEN+CHKIN first for non-keyboard.", input: nil, output: "A=Byte read", usedRegisters: "A, Y", realAddress: 0xF157),
        KernalRoutine(address: 0xFFD2, name: "CHROUT", description: "Write byte to default output. Must call OPEN+CHKOUT first for non-screen.", input: "A=Byte to write", output: nil, usedRegisters: "—", realAddress: 0xF1CA),
        KernalRoutine(address: 0xFFD5, name: "LOAD", description: "Load or verify file. Must call SETLFS and SETNAM first.", input: "A: 0=Load, 1-255=Verify; X/Y=Load address (if secondary=0)", output: "Carry: 0=OK, 1=Error; A=Error code; X/Y=End address", usedRegisters: "A, X, Y", realAddress: 0xF49E),
        KernalRoutine(address: 0xFFD8, name: "SAVE", description: "Save memory to file. Must call SETLFS and SETNAM first.", input: "A=ZP ptr to start address; X/Y=End address+1", output: "Carry: 0=OK, 1=Error; A=Error code", usedRegisters: "A, X, Y", realAddress: 0xF5DD),
        KernalRoutine(address: 0xFFDB, name: "SETTIM", description: "Set Time of Day clock at $00A0-$00A2.", input: "A/X/Y=New TOD value", output: nil, usedRegisters: "—", realAddress: 0xF6E4),
        KernalRoutine(address: 0xFFDE, name: "RDTIM", description: "Read Time of Day clock at $00A0-$00A2.", input: nil, output: "A/X/Y=Current TOD value", usedRegisters: "A, X, Y", realAddress: 0xF6DD),
        KernalRoutine(address: 0xFFE1, name: "STOP", description: "Query Stop key indicator at $0091; if pressed, call CLRCHN and clear keyboard buffer.", input: nil, output: "Zero: 0=Not pressed, 1=Pressed; Carry: 1=Pressed", usedRegisters: "A, X", realAddress: 0xF6ED),
        KernalRoutine(address: 0xFFE4, name: "GETIN", description: "Read byte from default input (non-blocking for keyboard). Must call OPEN+CHKIN for non-keyboard.", input: nil, output: "A=Byte read (0 if keyboard buffer empty)", usedRegisters: "A, X, Y", realAddress: 0xF13E),
        KernalRoutine(address: 0xFFE7, name: "CLALL", description: "Clear file table; call CLRCHN.", input: nil, output: nil, usedRegisters: "A, X", realAddress: 0xF32F),
        KernalRoutine(address: 0xFFEA, name: "UDTIM", description: "Update Time of Day ($00A0-$00A2) and Stop key indicator ($0091).", input: nil, output: nil, usedRegisters: "A, X", realAddress: 0xF69B),
        KernalRoutine(address: 0xFFED, name: "SCREEN", description: "Fetch number of screen rows and columns.", input: nil, output: "X=Columns (40), Y=Rows (25)", usedRegisters: "X, Y", realAddress: 0xE505),
        KernalRoutine(address: 0xFFF0, name: "PLOT", description: "Save or restore cursor position.", input: "Carry: 0=Set from X/Y, 1=Read to X/Y; X=Column, Y=Row", output: "X=Column, Y=Row (if Carry=1)", usedRegisters: "X, Y", realAddress: 0xE50A),
        KernalRoutine(address: 0xFFF3, name: "IOBASE", description: "Fetch CIA #1 base address.", input: nil, output: "X/Y=CIA #1 base ($DC00)", usedRegisters: "X, Y", realAddress: 0xE500),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - Color Palette
    // ══════════════════════════════════════════════════════════

    public static let colorPalette: [C64Color] = [
        C64Color(index: 0,  name: "Black",       hex: "#000000"),
        C64Color(index: 1,  name: "White",        hex: "#FFFFFF"),
        C64Color(index: 2,  name: "Red",          hex: "#883932"),
        C64Color(index: 3,  name: "Cyan",         hex: "#67B6BD"),
        C64Color(index: 4,  name: "Purple",       hex: "#8B3F96"),
        C64Color(index: 5,  name: "Green",        hex: "#55A049"),
        C64Color(index: 6,  name: "Blue",         hex: "#40318D"),
        C64Color(index: 7,  name: "Yellow",       hex: "#BFCE72"),
        C64Color(index: 8,  name: "Orange",       hex: "#8B5429"),
        C64Color(index: 9,  name: "Brown",        hex: "#574200"),
        C64Color(index: 10, name: "Light Red",    hex: "#B86962"),
        C64Color(index: 11, name: "Dark Gray",    hex: "#505050"),
        C64Color(index: 12, name: "Medium Gray",  hex: "#787878"),
        C64Color(index: 13, name: "Light Green",  hex: "#94E089"),
        C64Color(index: 14, name: "Light Blue",   hex: "#7869C4"),
        C64Color(index: 15, name: "Light Gray",   hex: "#9F9F9F"),
    ]

    // ══════════════════════════════════════════════════════════
    // MARK: - Lookup Methods
    // ══════════════════════════════════════════════════════════

    /// Searches the static memory map entries for a region containing the given address.
    /// Note: Linear scan optimized for compile-time static data, not runtime performance-critical paths.
    public static func lookup(address: UInt16) -> MemoryMapEntry? {
        let allEntries = zeroPageEntries + stackAndBufferEntries + screenMemoryEntries +
            basicAreaEntries + vicRegisters + sidRegisters + colorRAMEntries +
            cia1Registers + cia2Registers + kernalAreaEntries

        for entry in allEntries {
            if let end = entry.endAddress {
                if address >= entry.address && address <= end { return entry }
            } else if address == entry.address {
                return entry
            }
        }
        return nil
    }

    /// Searches the static memory map entries for a region containing the given decimal address.
    public static func lookup(decimalAddress: Int) -> MemoryMapEntry? {
        guard decimalAddress >= 0 && decimalAddress <= 65535 else { return nil }
        return lookup(address: UInt16(decimalAddress))
    }

    /// Finds a KERNAL routine by its entry point address.
    public static func lookupKernal(address: UInt16) -> KernalRoutine? {
        return kernalRoutines.first { $0.address == address }
    }
}

