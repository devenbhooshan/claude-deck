import AppKit
import PDFKit
import SwiftUI
import WebKit

/// A PDF, image or web page Claude made or mentioned, shown in its own Deck window.
/// It reloads when the file changes, so a report Claude rewrites stays current.
struct FileViewer: View {
    let url: URL
    @State private var version = 0
    @State private var watcher: FileWatcher?
    @State private var exists = true

    var body: some View {
        Group {
            if !exists {
                ContentUnavailableView("File not found", systemImage: "doc.questionmark",
                                       description: Text(Theme.shortPath(url.path)))
            } else {
                switch FileLinks.kind(of: url) {
                case .pdf: PDFFileView(url: url, version: version)
                case .image: ImageFileView(url: url, version: version)
                case .html: WebFileView(url: url, version: version)
                case nil: ContentUnavailableView("Deck can't show this file", systemImage: "doc")
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Theme.surface)
        .navigationTitle(url.lastPathComponent)
        .navigationSubtitle(Theme.shortPath(url.deletingLastPathComponent().path))
        .toolbar {
            ToolbarItemGroup {
                Button { reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                    .help("Reload (⌘R)")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show in Finder")
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open in \(defaultApp ?? "Default App")", systemImage: "arrow.up.forward.app")
                }
                .help("Open in \(defaultApp ?? "the default app")")
            }
        }
        .onAppear { reload() }
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
    @State private var actualSize = false

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: actualSize ? image.size.width : nil, maxHeight: actualSize ? image.size.height : nil)
                        .frame(width: actualSize ? image.size.width : nil, height: actualSize ? image.size.height : nil)
                        .padding(16)
                }
                .defaultScrollAnchor(.center)
                .onTapGesture(count: 2) { actualSize.toggle() }
                .help(actualSize ? "Double-click to fit the window" : "Double-click for actual size")
            } else {
                ContentUnavailableView("Can't read this image", systemImage: "photo")
            }
        }
        .task(id: version) {
            let url = url
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
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
