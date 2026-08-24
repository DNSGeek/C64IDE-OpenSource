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

                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    if Self.isBreakpointHit(trimmed) {
                        onBreakpoint?(trimmed)
                    }
                    onResponse?(trimmed)
                }
            }
        }
    }

    /// True only for VICE's "the CPU stopped here" announcement, which looks
    /// like `#1 (Stop on  exec 0810)   0810`.
    ///
    /// Deliberately does *not* match `BREAK: 1  C:$0810  (Stop on exec)` —
    /// that's a row of `break`'s breakpoint *listing*. Treating those as hits
    /// made every `refreshBreakpointMap()` fire a phantom breakpoint event for
    /// each breakpoint that existed.
    private static func isBreakpointHit(_ line: String) -> Bool {
        line.hasPrefix("#") && line.contains("(Stop")
    }
}
