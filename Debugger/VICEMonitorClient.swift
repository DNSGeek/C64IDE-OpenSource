import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - VICEMonitorClient
// ═══════════════════════════════════════════════════════════

/// Connects to VICE's remote text monitor via TCP.
///
/// VICE must be launched with: `-remotemonitor -remotemonitoraddress 127.0.0.1:6510`
/// This client handles connection lifecycle, command dispatch, and response parsing.
class VICEMonitorClient {

    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readThread: Thread?
    private var isConnected = false
    private let host: String
    private let port: UInt32

    /// Called when data is received from VICE
    var onResponse: ((String) -> Void)?

    /// Called when connection state changes
    var onConnectionChanged: ((Bool) -> Void)?

    /// Called when VICE hits a breakpoint (response contains register dump)
    var onBreakpoint: ((String) -> Void)?

    init(host: String = "127.0.0.1", port: UInt32 = 6510) {
        self.host = host
        self.port = port
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    var connected: Bool { isConnected }

    /// Establishes a TCP connection to the VICE monitor.
    /// Returns `true` if connected, `false` otherwise.
    func connect() -> Bool {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(nil, host as CFString, port, &readStream, &writeStream)

        guard let read = readStream?.takeRetainedValue(),
              let write = writeStream?.takeRetainedValue() else {
            return false
        }

        inputStream = read as InputStream
        outputStream = write as OutputStream

        inputStream?.open()
        outputStream?.open()

        // Wait briefly for connection handshake
        Thread.sleep(forTimeInterval: 0.2)

        guard outputStream?.streamStatus == .open else {
            disconnect()
            return false
        }

        isConnected = true
        onConnectionChanged?(true)

        // Start reading responses on a background thread
        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.name = "VICEMonitor-Read"
        readThread?.start()

        return true
    }

    /// Gracefully disconnects and cleans up resources.
    func disconnect() {
        isConnected = false
        readThread?.cancel()
        readThread = nil
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        onConnectionChanged?(false)
    }

    // MARK: - Commands

    /// Sends a raw command string to the VICE monitor.
    func send(_ command: String) {
        guard isConnected, let output = outputStream else { return }
        let cmd = command + "\n"
        let data = [UInt8](cmd.utf8)
        output.write(data, maxLength: data.count)
    }

    /// Requests a register dump.
    func registers() { send("r") }

    /// Reads a memory range.
    func readMemory(start: UInt16, end: UInt16) {
        send(String(format: "m %04x %04x", start, end))
    }

    /// Disassembles at a given address.
    func disassemble(at address: UInt16, lines: Int = 16) {
        send(String(format: "d %04x", address))
    }

    /// Sets a hardware breakpoint at an address.
    func setBreakpoint(at address: UInt16) {
        send(String(format: "break %04x", address))
    }

    /// Deletes a breakpoint by its numeric ID.
    func deleteBreakpoint(_ number: Int) {
        send("delete \(number)")
    }

    /// Lists all active breakpoints.
    func listBreakpoints() { send("break") }

    /// Continues execution (exits the monitor).
    func continueExecution() { send("x") }

    /// Jumps to a specific address.
    func goto(address: UInt16) {
        send(String(format: "g %04x", address))
    }

    /// Steps one instruction.
    func step() { send("z") }

    /// Steps over (next) a function call.
    func stepOver() { send("n") }

    /// Steps out (returns from) the current function.
    func stepOut() { send("ret") }

    /// Writes a single byte to memory.
    func writeByte(address: UInt16, value: UInt8) {
        send(String(format: "> %04x %02x", address, value))
    }

    /// Writes multiple bytes to memory.
    func writeBytes(address: UInt16, data: [UInt8]) {
        let hexData = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        send(String(format: "> %04x %@", address, hexData))
    }

    /// Shows the call stack.
    func callStack() { send("bt") }

    /// Sets the current bank.
    func setBank(_ bank: String) { send("bank \(bank)") }

    /// Fills a memory range with specified bytes.
    func fill(start: UInt16, end: UInt16, values: [UInt8]) {
        let hexData = values.map { String(format: "%02x", $0) }.joined(separator: " ")
        send(String(format: "f %04x %04x %@", start, end, hexData))
    }

    /// Compares two memory ranges.
    func compare(start: UInt16, end: UInt16, address: UInt16) {
        send(String(format: "c %04x %04x %04x", start, end, address))
    }

    /// Hunts for a byte pattern in memory.
    func hunt(start: UInt16, end: UInt16, values: [UInt8]) {
        let hexData = values.map { String(format: "%02x", $0) }.joined(separator: " ")
        send(String(format: "h %04x %04x %@", start, end, hexData))
    }

    // MARK: - Read Loop

    /// Continuously reads from the input stream, parsing complete lines
    /// and dispatching callbacks to the main queue.
    ///
    /// Uses a RunLoop with a 250ms timeout to efficiently block until
    /// data arrives, avoiding busy-polling while maintaining responsiveness.
    private func readLoop() {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var accumulated = ""

        guard let input = inputStream else { return }
        input.schedule(in: .current, forMode: .default)

        while isConnected && !Thread.current.isCancelled {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))

            while input.hasBytesAvailable {
                let bytesRead = input.read(&buffer, maxLength: bufferSize)

                if bytesRead <= 0 {
                    if bytesRead < 0 {
                        DispatchQueue.main.async { [weak self] in
                            self?.disconnect()
                        }
                    }
                    return
                }

                let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                accumulated += text

                // Process complete lines
                while let newlineRange = accumulated.range(of: "\n") {
                    let line = String(accumulated[accumulated.startIndex..<newlineRange.lowerBound])
                    accumulated = String(accumulated[newlineRange.upperBound...])

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    DispatchQueue.main.async { [weak self] in
                        if trimmed.contains("BREAK:") || trimmed.contains("#") && trimmed.contains("(Stop") {
                            self?.onBreakpoint?(trimmed)
                        }
                        self?.onResponse?(trimmed)
                    }
                }
            }
        }

        input.remove(from: .current, forMode: .default)
    }
}

