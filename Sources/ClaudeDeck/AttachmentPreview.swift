import AppKit
import QuickLookUI
import SwiftUI

/// An unsent attachment shown over the window when you click it in a message box: an image at
/// actual size (or as large as fits), markdown rendered, any other file through Quick Look (text,
/// PDFs, spreadsheets...). Esc, Done or a click outside closes it; it stays attached. While it's
/// open, keys don't reach the message box underneath, so Return can't send by accident.
struct AttachmentPreviewOverlay: View {
    @Environment(SessionStore.self) private var store
    let attachment: Attachment
    @State private var keyMonitor: Any?

    /// Room left around the card, so there's always somewhere outside it to click.
    private static let margin: CGFloat = 60
    private static let headerHeight: CGFloat = 50

    var body: some View {
        GeometryReader { geo in
            let area = CGSize(width: geo.size.width - Self.margin * 2,
                              height: geo.size.height - Self.margin * 2 - Self.headerHeight)
            ZStack {
                // A button, not a tap gesture, so it's also there for VoiceOver.
                Button(action: close) { Color.black.opacity(0.4).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close preview")
                    .ignoresSafeArea()
                card(in: area)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: watchKeys)
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    }

    private func card(in area: CGSize) -> some View {
        let image = attachment.isImage ? NSImage(contentsOf: attachment.url) : nil
        // An image's card fits the image; a document gets a reading-width page.
        let fitted = image.map { fit(actualSize(of: $0), in: CGSize(width: area.width - 32, height: area.height - 32)) }
        let width = fitted.map { max(440, $0.width + 32) } ?? min(area.width, 900)
        return VStack(spacing: 0) {
            header.frame(height: Self.headerHeight)
            Divider()
            Group {
                if let image, let fitted {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .padding(16)
                } else if FileLinks.kind(of: attachment.url) == .markdown, let text = try? String(contentsOf: attachment.url, encoding: .utf8) {
                    MarkdownPreview(text: text, base: attachment.url.deletingLastPathComponent()) { NSWorkspace.shared.open($0) }
                        .frame(height: area.height)
                } else {
                    QuickLookView(url: attachment.url)
                        .frame(height: area.height)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: min(width, area.width))
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.url.path))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.isImage ? "Image" : attachment.name)
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(["Not sent yet", detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button { NSWorkspace.shared.open(attachment.url) } label: {
                Label("Open in \(defaultApp ?? "App")", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.deck(size: .small))
            .help("Open in \(defaultApp ?? "the default app")")
            Button("Done", action: close)
                .buttonStyle(.deck(.primary, size: .small))
                .help("Close (Esc); it stays attached")
        }
        .padding(.horizontal, 14)
    }

    /// The size it shows at on screen: a screenshot's pixels at the screen's scale.
    private func actualSize(of image: NSImage) -> CGSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return image.size }
        let scale = NSApp.keyWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
    }

    private func fit(_ size: CGSize, in area: CGSize) -> CGSize {
        let scale = ImageZoom.fit(size, in: area, margin: 0)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// "1040 × 600" for an image, "36 bytes" for a file.
    private var detail: String? {
        if attachment.isImage, let rep = NSImageRep(contentsOf: attachment.url) {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }
        guard let bytes = (try? attachment.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var defaultApp: String? {
        NSWorkspace.shared.urlForApplication(toOpen: attachment.url).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    private func close() { store.previewing = nil }

    private func watchKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { close(); return nil }   // Esc
            // ⌘ shortcuts still work; plain keys (Return!) don't reach the message box underneath.
            return event.modifierFlags.contains(.command) ? event : nil
        }
    }
}

/// Quick Look's own preview, inside the window.
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
