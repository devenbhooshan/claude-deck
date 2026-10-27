import AppKit
import PDFKit
import SwiftUI
import WebKit

struct ViewedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// A PDF, image or web page Claude made or mentioned, shown as a sheet over the session.
/// It reloads when the file changes, so a report Claude rewrites stays current.
struct FileViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var version = 0
    @State private var watcher: FileWatcher?
    @State private var exists = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if !exists {
                    ContentUnavailableView("File not found", systemImage: "doc.questionmark",
                                           description: Text(Theme.shortPath(url.path)))
                } else {
                    switch FileLinks.kind(of: url) {
                    case .pdf: PDFFileView(url: url, version: version)
                    case .image: ImageFileView(url: url, version: version)
                    case .html: WebFileView(url: url, version: version)
                    case .markdown, nil: ContentUnavailableView("Deck can't show this file", systemImage: "doc")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 760)
        .background(Theme.surface)
        .onAppear { reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(Theme.shortPath(url.deletingLastPathComponent().path))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.deck(size: .small))
                .keyboardShortcut("r")
                .help("Reload (⌘R)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.deck(size: .small))
                .help("Show in Finder")
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Open in \(defaultApp ?? "App")", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.deck(size: .small))
            .help("Open in \(defaultApp ?? "the default app")")
            Button("Done") { dismiss() }
                .buttonStyle(.deck(.primary, size: .small))
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var icon: String {
        switch FileLinks.kind(of: url) {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .html, .markdown, nil: "globe"
        }
    }

    private var defaultApp: String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Re-reads the file and watches it again: editors and Claude often replace the file
    /// rather than write into it, which ends the old watch.
    private func reload() {
        exists = FileManager.default.fileExists(atPath: url.path)
        version += 1
        watcher = FileWatcher(url: url, events: [.write, .rename, .delete, .extend]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reload() }
        }
    }
}

private struct PDFFileView: NSViewRepresentable {
    let url: URL
    let version: Int

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        guard context.coordinator.version != version else { return }
        context.coordinator.version = version
        // Keep your place across reloads.
        let page = v.currentPage.flatMap { v.document?.index(for: $0) }
        v.document = PDFDocument(url: url)
        if let page, let p = v.document?.page(at: min(page, (v.document?.pageCount ?? 1) - 1)) { v.go(to: p) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var version = -1 }
}

private struct ImageFileView: View {
    let url: URL
    let version: Int
    @State private var image: NSImage?
    /// Nil: fitted to the window. Otherwise the scale you zoomed to (1 = actual size).
    @State private var zoom: CGFloat?
    /// The scale when a pinch began, and the fitted scale (for zooming from the wheel).
    @State private var pinchStart: CGFloat?
    @State private var fitScale: CGFloat = 1
    @State private var wheelMonitor: Any?

    var body: some View {
        Group {
            if let image {
                GeometryReader { geo in
                    let fit = ImageZoom.fit(image.size, in: geo.size)
                    let scale = zoom ?? fit
                    Group {
                        if zoom == nil {
                            // Fits the window whole: no scrolling either way.
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: image.size.width * fit, height: image.size.height * fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            // Zoomed: scroll around when it's bigger than the window; centred when smaller.
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                                    .padding(16)
                                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                            }
                            .defaultScrollAnchor(.center)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { zoom = zoom == nil && fit < 1 ? 1 : nil }
                    .help(zoom == nil ? "Double-click for actual size" : "Double-click to fit the window")
                    .overlay(alignment: .bottom) { zoomBar(scale: scale, fit: fit) }
                    // Pinch on the trackpad.
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { g in
                            let start = pinchStart ?? scale
                            pinchStart = start
                            zoom = ImageZoom.scaled(start, by: g.magnification)
                        }
                        .onEnded { _ in pinchStart = nil })
                    .onAppear { fitScale = fit }
                    .onChange(of: fit) { fitScale = fit }
                }
            } else {
                ContentUnavailableView("Can't read this image", systemImage: "photo")
            }
        }
        .task(id: version) {
            let url = url
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
        // ⌘ or ⌥ with the scroll wheel zooms, as in Preview; plain scrolling moves around.
        .onAppear {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                guard image != nil, !e.modifierFlags.isDisjoint(with: [.command, .option]), e.scrollingDeltaY != 0 else { return e }
                zoom = ImageZoom.scaled(zoom ?? fitScale, by: ImageZoom.wheelFactor(e.scrollingDeltaY))
                return nil
            }
        }
        .onDisappear { if let m = wheelMonitor { NSEvent.removeMonitor(m) } }
    }

    private func zoomBar(scale: CGFloat, fit: CGFloat) -> some View {
        HStack(spacing: 2) {
            Button { zoom = ImageZoom.step(scale, in: false) } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale <= ImageZoom.range.lowerBound)
                .help("Zoom out (⌘−)")
            Button { zoom = 1 } label: {
                Text(ImageZoom.percent(scale)).monospacedDigit().frame(minWidth: 46, minHeight: 22)
            }
            .help("Actual size")
            Button { zoom = ImageZoom.step(scale, in: true) } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(scale >= ImageZoom.range.upperBound)
                .help("Zoom in (⌘+)")
            Divider().frame(height: 14).padding(.horizontal, 4)
            Button { zoom = nil } label: {
                Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left").frame(minHeight: 22).padding(.horizontal, 4)
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(zoom == nil)
            .help("Fit the window (⌘0)")
        }
        .font(.callout)
        .buttonStyle(.deckPlain)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .padding(.bottom, 14)
    }
}

/// Local web pages. Links to the web open in your browser; the page can only read files
/// from its own folder.
private struct WebFileView: NSViewRepresentable {
    let url: URL
    let version: Int

    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.navigationDelegate = context.coordinator
        v.setValue(false, forKey: "drawsBackground")
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        guard context.coordinator.version != version else { return }
        context.coordinator.version = version
        v.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var version = -1

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let link = action.request.url, !link.isFileURL {
                if let scheme = link.scheme?.lowercased(), TranscriptTextController.openableSchemes.contains(scheme) {
                    NSWorkspace.shared.open(link)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
