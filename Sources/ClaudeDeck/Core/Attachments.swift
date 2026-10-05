import AppKit
import UniformTypeIdentifiers

/// A file staged in the composer, copied into Deck's cache. Images are saved under a space-free
/// name so the pasted path is recognized by Claude Code as a single image; other files keep
/// their name (in a folder of their own) and are passed to Claude as a path to read.
struct Attachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// Set for images; nil for other files.
    let thumbnail: NSImage?

    init(url: URL, thumbnail: NSImage?) {
        self.id = UUID()
        self.url = url
        self.thumbnail = thumbnail
    }

    var isImage: Bool { thumbnail != nil }
    var name: String { url.lastPathComponent }
}

enum AttachmentStore {
    /// Where staged files are saved. Tests point this at a temporary folder.
    nonisolated(unsafe) static var dir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.devenbhooshan.claudedeck/attachments")

    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Deletes staged files older than `age` (they're only needed until Claude has read them).
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
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let ext = fileURL.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            guard (try? fm.copyItem(at: fileURL, to: dest)) != nil else { return nil }
            if let image = NSImage(contentsOf: dest) { return Attachment(url: dest, thumbnail: image) }
            // Not actually an image: don't leave the copy behind, send it as a plain file.
            try? fm.removeItem(at: dest)
        } else if UTType(filenameExtension: ext)?.conforms(to: .image) == true, let image = NSImage(contentsOf: fileURL) {
            // Other image formats (HEIC, TIFF, ...) are converted to PNG.
            return from(image: image)
        }
        return file(fileURL)
    }

    /// Any other file (CSV, PDF, text, ...): copied as-is, keeping its name.
    private static func file(_ fileURL: URL) -> Attachment? {
        let folder = dir.appendingPathComponent(UUID().uuidString)
        let dest = folder.appendingPathComponent(fileURL.lastPathComponent)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              (try? FileManager.default.copyItem(at: fileURL, to: dest)) != nil else { return nil }
        return Attachment(url: dest, thumbnail: nil)
    }

    /// The message typed into Claude: your text, then one line per attached (non-image) file.
    static func message(_ text: String, files: [Attachment]) -> String {
        let lines = files.map { "Attached file: \($0.url.path)" }.joined(separator: "\n")
        if lines.isEmpty { return text }
        return text.isEmpty ? lines : text + "\n\n" + lines
    }

    static func from(image: NSImage) -> Attachment? {
        ensureDir()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dest = dir.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? png.write(to: dest)) != nil else { return nil }
        return Attachment(url: dest, thumbnail: image)
    }

    /// Files on the pasteboard first, then raw image data (screenshots).
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

    /// ⌘V attaches instead of pasting text when the clipboard holds files, or image data with
    /// no plain text (a screenshot). Rich text that merely includes an image pastes as text.
    static func shouldAttach(from pb: NSPasteboard) -> Bool {
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return pb.string(forType: .string) == nil && pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}
