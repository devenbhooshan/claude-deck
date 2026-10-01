import Foundation

/// Calls `onChange` on the main queue when a file or directory changes.
final class FileWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32

    init?(url: URL, events: DispatchSource.FileSystemEvent, onChange: @escaping () -> Void) {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler(handler: onChange)
        let fd = fd
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
