import AppKit
import UniformTypeIdentifiers

/// An image staged in the composer. It is saved to a space-free cache path so the
/// pasted path is recognized by Claude Code as a single image file.
struct Attachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let thumbnail: NSImage

    init(url: URL, thumbnail: NSImage) {
        self.id = UUID()
        self.url = url
        self.thumbnail = thumbnail
    }
}

enum AttachmentStore {
    /// Where staged images are saved. Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.devenbhooshan.claudedeck/attachments")

    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Deletes staged images older than `age` (they're only needed until Claude has read them).
    static func purge(olderThan age: TimeInterval = 86400, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            guard let modified = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: f) }
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func from(fileURL: URL) -> Attachment? {
        ensureDir()
        let ext = fileURL.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            guard (try? FileManager.default.copyItem(at: fileURL, to: dest)) != nil else { return nil }
            guard let image = NSImage(contentsOf: dest) else {
                // Not actually an image: don't leave the copy behind.
                try? FileManager.default.removeItem(at: dest)
                return nil
            }
            return Attachment(url: dest, thumbnail: image)
        }
        // Other image formats (HEIC, TIFF, ...) are converted to PNG.
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        return from(image: image)
    }

    static func from(image: NSImage) -> Attachment? {
        ensureDir()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dest = dir.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? png.write(to: dest)) != nil else { return nil }
        return Attachment(url: dest, thumbnail: image)
    }

    /// Images on the pasteboard: copied files first, then raw image data (screenshots).
    static func from(pasteboard pb: NSPasteboard) -> [Attachment] {
        let found = fileURLs(pb).compactMap(from(fileURL:))
        if !found.isEmpty { return found }
        return objects(pb.readObjects(forClasses: [NSImage.self]), as: NSImage.self).compactMap(from(image:))
    }

    private static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        objects(pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]), as: URL.self)
    }

    /// The objects of one type from a pasteboard read (which is nil only on a read error).
    static func objects<T>(_ read: [Any]?, as type: T.Type) -> [T] {
        (read ?? []).compactMap { $0 as? T }
    }

    /// ⌘V attaches instead of pasting text when the clipboard holds image files, or image data
    /// with no plain text (a screenshot). Rich text that merely includes an image pastes as text.
    static func shouldAttach(from pb: NSPasteboard) -> Bool {
        let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let hasPlainText = pb.string(forType: .string) != nil
        return (hasFiles || !hasPlainText) && hasImage(pb)
    }

    static func hasImage(_ pb: NSPasteboard) -> Bool {
        fileURLs(pb).contains { NSImage(contentsOf: $0) != nil } || pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

}
