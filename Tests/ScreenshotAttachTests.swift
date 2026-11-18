import Foundation

func screenshotAttachTests() {
    test("screenshot folder: the saved location, ~ expanded, else the Desktop") {
        let box = Sandbox(); defer { box.cleanup() }
        let home = box.root.path
        let desktop = box.root.appendingPathComponent("Desktop").path
        let shots = box.root.appendingPathComponent("Shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        box.write("file.txt", "x")
        expectEqual(Screenshots.folder(location: nil, home: home).path, desktop)
        expectEqual(Screenshots.folder(location: "  ", home: home).path, desktop)
        expectEqual(Screenshots.folder(location: "~/Shots", home: home).path, shots.path)
        expectEqual(Screenshots.folder(location: "~", home: home).path, home)
        expectEqual(Screenshots.folder(location: shots.path, home: home).path, shots.path)
        expectEqual(Screenshots.folder(location: "~/Gone", home: home).path, desktop)  // deleted since
        expectEqual(Screenshots.folder(location: "~/file.txt", home: home).path, desktop)  // not a folder
        expect(!Screenshots.folder().path.isEmpty)  // the real setting: some folder, whatever it is
    }
    test("latest screenshot: newest image by creation date") {
        let box = Sandbox(); defer { box.cleanup() }
        let folder = box.root.appendingPathComponent("Shots")
        expect(Screenshots.latest(in: folder) == nil, "no folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        expect(Screenshots.latest(in: folder) == nil, "empty folder")
        let now = Date()
        func make(_ name: String, ago: TimeInterval) throws -> URL {
            let url = box.write("Shots/\(name)", "made up")
            try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-ago)], ofItemAtPath: url.path)
            return url
        }
        _ = try make("Screenshot old.png", ago: 300)
        let newest = try make("Screenshot new.JPG", ago: 10)
        _ = try make("Screenshot mid.heic", ago: 100)
        _ = try make("notes.txt", ago: 1)                // not an image
        _ = try make(".Screenshot writing.png", ago: 0)  // hidden: still being written
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
        expectEqual(Screenshots.latest(in: folder)?.lastPathComponent, newest.lastPathComponent)
        expect(Screenshots.isImage(URL(fileURLWithPath: "/a/b.tiff")))
        expect(!Screenshots.isImage(URL(fileURLWithPath: "/a/b")))
    }
    test("screenshot temp files: detected in paths, escaped paths and file URLs") {
        let dir = "/var/folders/ab/xyz/T/TemporaryItems/NSIRD_screencaptureui_Q1w2E3"
        expect(Screenshots.isTemporary(URL(fileURLWithPath: dir + "/Screenshot.png")))
        expect(!Screenshots.isTemporary(URL(fileURLWithPath: "/Users/me/Desktop/Screenshot.png")))

        let plain = "\(dir)/Screenshot 2026-11-18 at 10.15.32.png"
        expectEqual(Screenshots.temporaryPaths(in: "look at \(plain) please").map(\.url.path), [plain])
        let escaped = "\(dir)/Screenshot\\ 2026-11-18\\ at\\ 10.15.32.png"
        expectEqual(Screenshots.temporaryPaths(in: escaped).map(\.url.path), [plain])
        let url = "file://\(dir)/Screenshot%202026-11-18%20at%2010.15.32.png"
        expectEqual(Screenshots.temporaryPaths(in: "'\(url)'").map(\.url.path), [plain])
        let two = Screenshots.temporaryPaths(in: "\(dir)/a.png\n\(dir)/b.JPEG")
        expectEqual(two.map(\.url.lastPathComponent), ["a.png", "b.JPEG"])
        // Ordinary paths, and the temp folder without a file in it, are left alone.
        expect(Screenshots.temporaryPaths(in: "/Users/me/Desktop/Screenshot.png").isEmpty)
        expect(Screenshots.temporaryPaths(in: "\(dir)/notes.txt").isEmpty)
        expect(Screenshots.temporaryPaths(in: "x\(dir)/a.png").isEmpty, "not the start of a path")
    }
    test("screenshot temp files: copied out and their paths taken out of the text") {
        let dir = "/T/TemporaryItems/NSIRD_screencaptureui_abc"
        let a = "\(dir)/Screenshot one.png", b = "\(dir)/two.png"
        let all = Screenshots.rescue("see \(a) and \(b) here", attach: { $0.lastPathComponent })
        expectEqual(all.text, "see and here")
        expectEqual(all.attached, ["Screenshot one.png", "two.png"])
        let first = Screenshots.rescue("\(a) what's wrong?", attach: { $0.path })
        expectEqual(first.text, "what's wrong?")
        // Already deleted by macOS: nothing to copy, the text stays as typed.
        let gone = Screenshots.rescue("see \(a)", attach: { _ -> String? in nil })
        expectEqual(gone.text, "see \(a)")
        expect(gone.attached.isEmpty)
        let none = Screenshots.rescue("  nothing here ", attach: { $0.path })
        expectEqual(none.text, "  nothing here ")
    }
    test("screenshot temp files: the copy outlives the temp file") {
        let box = Sandbox(); defer { box.cleanup() }
        let temp = box.root.appendingPathComponent("TemporaryItems/NSIRD_screencaptureui_x1/Screenshot 1.png")
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData().write(to: temp)
        let result = Screenshots.rescue("bug: \(temp.path)", attach: AttachmentStore.from(fileURL:))
        try FileManager.default.removeItem(at: temp.deletingLastPathComponent())  // the thumbnail closed
        expectEqual(result.text, "bug:")
        expectEqual(result.attached.count, 1)
        expect(result.attached.first?.isImage == true)
        expect(result.attached.first.map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
        expect(result.attached.first?.url.path.hasPrefix(AttachmentStore.dir.path) == true)
    }
}
