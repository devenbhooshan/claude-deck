import AppKit
import UniformTypeIdentifiers

extension AttachmentStore {
    static func pick() -> [Attachment] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images or files to send to Claude"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap(from(fileURL:))
    }
}
