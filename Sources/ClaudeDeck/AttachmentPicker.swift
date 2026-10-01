import AppKit
import UniformTypeIdentifiers

extension AttachmentStore {
    static func pick() -> [Attachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images to send to Claude"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(from(fileURL:))
    }
}
