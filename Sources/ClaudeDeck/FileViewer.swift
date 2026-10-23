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
