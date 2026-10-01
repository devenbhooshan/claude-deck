import AppKit
import UniformTypeIdentifiers

/// An image staged in the composer. It is saved to a space-free cache path so the
/// pasted path is recognized by Claude Code as a single image file.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage
}

enum AttachmentStore {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("com.devenbhooshan.claudedeck/attachments")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func from(fileURL: URL) -> Attachment? {
        let ext = fileURL.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            guard (try? FileManager.default.copyItem(at: fileURL, to: dest)) != nil,
                  let image = NSImage(contentsOf: dest) else { return nil }
            return Attachment(url: dest, thumbnail: image)
        }
        // Other image formats (HEIC, TIFF, ...) are converted to PNG.
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        return from(image: image)
    }

    static func from(image: NSImage) -> Attachment? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dest = dir.appendingPathComponent("\(UUID().uuidString).png")
        guard (try? png.write(to: dest)) != nil else { return nil }
        return Attachment(url: dest, thumbnail: image)
    }

    /// Images on the pasteboard: copied files first, then raw image data (screenshots).
    static func from(pasteboard pb: NSPasteboard) -> [Attachment] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let found = urls.compactMap(from(fileURL:))
            if !found.isEmpty { return found }
        }
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            return images.compactMap(from(image:))
        }
        return []
    }

    static func hasImage(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { NSImage(contentsOf: $0) != nil }) {
            return true
        }
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func pick() -> [Attachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images to send to Claude"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(from(fileURL:))
    }
}
