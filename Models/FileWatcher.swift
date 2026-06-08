import Foundation

/// Watches a single file on disk and invokes a callback when it is modified,
/// renamed, or deleted by another process. Re-establishes its watch after
/// atomic-rename saves so writes that happen later (e.g. another editor doing
/// a write-temp-then-rename save) are still observed.
public final class FileWatcher {

    /// The URL being observed.
    public let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    /// Creates a new file watcher that invokes `onChange` when the file changes.
    public init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        startWatching()
    }

    deinit { stop() }

    /// Stops watching and releases underlying file-descriptor resources.
    public func stop() {
        source?.cancel()
        source = nil
    }

    private func startWatching() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source = src

        src.setEventHandler { [weak self] in
            guard let self = self, let s = self.source else { return }
            let flags = s.data
            // If the file was replaced (atomic rename) or deleted, our fd is
            // now pointing at a stale inode. Cancel and re-arm so we observe
            // future writes to the file at the same path.
            let needsRearm = flags.contains(.delete) || flags.contains(.rename)
            self.onChange()
            if needsRearm {
                self.stop()
                // Briefly delay so atomic save (write tmp → rename) has a
                // chance to land before we re-open. This avoids a race condition
                // where we re-arm before the new file is fully visible on disk.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self = self else { return }
                    if FileManager.default.fileExists(atPath: self.url.path) {
                        self.startWatching()
                    }
                }
            }
        }

        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        src.resume()
    }
}

