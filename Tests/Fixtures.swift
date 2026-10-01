import AppKit

func session(_ id: String, status: SessionStatus = .idle, pid: Int32? = 1, cwd: String = "/tmp/project",
             title: String? = nil, name: String? = nil, waitingFor: String? = nil,
             updatedAt: Date = Date(timeIntervalSince1970: 1000), statusSince: Date? = nil,
             pendingTool: ToolCall? = nil) -> Session {
    Session(sessionId: id, pid: pid, cwd: cwd, name: name, title: title, status: status, waitingFor: waitingFor,
            updatedAt: updatedAt, transcriptURL: nil, statusSince: statusSince, pendingTool: pendingTool)
}

func item(_ kind: TranscriptItem.Kind, _ id: String = UUID().uuidString) -> TranscriptItem {
    TranscriptItem(id: id, kind: kind, timestamp: nil)
}

/// A 4×4 PNG, for image tests.
func pngData(width: Int = 4, height: Int = 4) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

func image(width: Int = 4, height: Int = 4) -> NSImage { NSImage(data: pngData(width: width, height: height))! }
