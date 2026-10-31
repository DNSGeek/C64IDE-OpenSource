import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - VICEMonitorClient
// ═══════════════════════════════════════════════════════════

/// Connects to VICE's remote text monitor via TCP.
///
/// VICE must be launched with: `-remotemonitor -remotemonitoraddress 127.0.0.1:6510`
/// This client owns the connection lifecycle, command dispatch, and line framing.
///
/// ## Threading contract
///
/// Callbacks fire on this client's internal read thread — **not** on the main
/// queue. That is deliberate. `VICERunTarget.synchronousRequest` blocks its
/// caller (usually the main thread) on a semaphore until the matching reply
/// arrives, so hopping to the main queue here would deadlock: the reply that
/// signals the semaphore can't be dispatched while the waiter owns the main
/// queue, and every request would sit out its full timeout. Consumers hop to
/// whichever queue they need themselves.
class VICEMonitorClient {

    /// Guards `_isConnected` and the two stream references, which are touched
    /// from both the caller's thread and the read thread.
    private let stateLock = NSLock()
    private var _isConnected = false

    /// Owned by the read thread once `readLoop` starts; it unschedules and
    /// closes the stream on its way out. Closing a scheduled CFStream from
    /// another thread is not safe, so `disconnect()` deliberately leaves it be.
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readThread: Thread?

    private let host: String
    private let port: UInt32

    /// Called for every complete line received from VICE.
    var onResponse: ((String) -> Void)?

    /// Called when the connection state changes.
    var onConnectionChanged: ((Bool) -> Void)?

    /// Called when VICE reports hitting a breakpoint.
    var onBreakpoint: ((String) -> Void)?

    init(host: String = "127.0.0.1", port: UInt32 = 6510) {
        self.host = host
        self.port = port
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    var connected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    /// Establishes a TCP connection to the VICE monitor.
    /// Returns `true` if connected, `false` otherwise.
    func connect() -> Bool {
        var readStream:  Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(nil, host as CFString, port, &readStream, &writeStream)

        guard let read  = readStream?.takeRetainedValue(),
              let write = writeStream?.takeRetainedValue() else {
            return false
        }

        let input  = read  as InputStream
        let output = write as OutputStream

        input.open()
        output.open()

        // Wait briefly for the connection handshake.
        Thread.sleep(forTimeInterval: 0.2)

        guard output.streamStatus == .open else {
            // No read thread exists yet, so tear both streams down here.
            input.close()
            output.close()
            return false
        }

        stateLock.lock()
        inputStream  = input
        outputStream = output
        _isConnected = true
        stateLock.unlock()

        onConnectionChanged?(true)

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "VICEMonitor-Read"
        stateLock.lock()
        readThread = thread
        stateLock.unlock()
        thread.start()

        return true
    }

    /// Marks the session closed and shuts down the write side. The read thread
    /// notices `connected == false` within one run-loop tick (250 ms) and
    /// closes the read side itself. Idempotent.
    func disconnect() {
        stateLock.lock()
        guard _isConnected else {
            stateLock.unlock()
            return
        }
        _isConnected = false
        let output = outputStream
        outputStream = nil
        let thread = readThread
        readThread = nil
        stateLock.unlock()

        output?.close()
        // Don't cancel the read thread from itself — it's already unwinding.
        if thread !== Thread.current { thread?.cancel() }

        onConnectionChanged?(false)
    }

    // MARK: - Commands

    /// Sends a raw command string to the VICE monitor.
    func send(_ command: String) {
        stateLock.lock()
        let output = _isConnected ? outputStream : nil
        let data = [UInt8]((command + "\n").utf8)
        output?.write(data, maxLength: data.count)
        stateLock.unlock()
    }

    // MARK: - Read Loop

    /// Continuously reads from the input stream and dispatches complete lines
    /// to `onResponse` / `onBreakpoint` on this thread.
    ///
    /// Uses a RunLoop with a 250 ms timeout to block until data arrives,
    /// avoiding busy-polling while staying responsive to `disconnect()`.
    private func readLoop() {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var accumulated = ""

        stateLock.lock()
        let input = inputStream
        stateLock.unlock()
        guard let input else { return }

        input.schedule(in: .current, forMode: .default)

        // Runs on every exit path, including the EOF/error returns below,
        // which previously leaked the stream's run-loop registration.
        defer {
            input.remove(from: .current, forMode: .default)
            input.close()
            stateLock.lock()
            inputStream = nil
            stateLock.unlock()
        }

        while connected && !Thread.current.isCancelled {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))

            while input.hasBytesAvailable {
                let bytesRead = input.read(&buffer, maxLength: bufferSize)

                // 0 means the peer closed the socket, negative means a read
                // error. Both end the session: leaving the client "connected"
                // kept the UI showing a live monitor and silently swallowed
                // every command written into the dead stream.
                guard bytesRead > 0 else {
                    disconnect()
                    return
                }

                accumulated += String(decoding: buffer[0..<bytesRead], as: UTF8.self)

                // Process complete lines.
                while let newlineRange = accumulated.range(of: "\n") {
                    let line = String(accumulated[accumulated.startIndex..<newlineRange.lowerBound])
                    accumulated = String(accumulated[newlineRange.upperBound...])
                    dispatch(line)
                }

                // The prompt has no newline after it. Hand it on as soon as
                // it is all that is left, so the reply it ends is complete
                // now rather than when the next one arrives.
                let (prompts, rest) = Self.splitPrompts(accumulated)
                if !prompts.isEmpty, rest.allSatisfy(\.isWhitespace) {
                    prompts.forEach { onResponse?($0) }
                    accumulated = ""
                }
            }
        }
    }

    /// Hands one line of monitor output to `onResponse` / `onBreakpoint`,
    /// with any prompts at its front as lines of their own.
    private func dispatch(_ line: String) {
        let (prompts, rest) = Self.splitPrompts(line)
        prompts.forEach { onResponse?($0) }

        // Only the end is trimmed: leading spaces line up the caret VICE
        // puts under a syntax error. The parsers trim for themselves.
        var text = String(rest)
        while text.last?.isWhitespace == true { text.removeLast() }
        guard !text.allSatisfy(\.isWhitespace) else { return }

        if VICEResponseParser.isCheckpointHit(text) {
            onBreakpoint?(text.trimmingCharacters(in: .whitespaces))
        }
        onResponse?(text)
    }

    /// VICE ends every reply with its prompt, `(C:$0821) `, and sends no
    /// newline after it. Split on newlines alone, the prompt waited until the
    /// next reply arrived and was then glued to the front of that reply's
    /// first line. Nothing ever saw a prompt line, so every request that ends
    /// at the prompt (memory, disassembly, breakpoint list) ran into its
    /// timeout and came back empty. This splits the prompts off the front of
    /// `text` (several when replies were empty) and returns the rest.
    private static func splitPrompts(_ text: String) -> (prompts: [String], rest: Substring) {
        var prompts: [String] = []
        var rest = Substring(text)
        while let match = rest.drop(while: \.isWhitespace).prefixMatch(of: /\([0-9A-Za-z]+:\$[0-9A-Fa-f]{4}\)/) {
            prompts.append(String(match.output))
            rest = rest[match.range.upperBound...]
        }
        return (prompts, rest)
    }
}
