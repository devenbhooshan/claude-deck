import Foundation

private func kinds(_ d: [DiffLine]) -> String {
    d.map { switch $0.kind { case .added: "+\($0.text)"; case .removed: "-\($0.text)"; case .context: " \($0.text)"; case .gap: "~" } }
        .joined(separator: "|")
}

func diffTests() {
    test("line diff: changes, removals before additions, edge cases") {
        expectEqual(kinds(LineDiff.diff(old: "a\nb\nc", new: "a\nB\nc")), " a|-b|+B| c")
        expectEqual(kinds(LineDiff.diff(old: "a\nb", new: "a\nb\nc")), " a| b|+c")
        expectEqual(kinds(LineDiff.diff(old: "x\na", new: "a")), "-x| a")
        expectEqual(kinds(LineDiff.diff(old: "", new: "n")), "+n")
        expectEqual(kinds(LineDiff.diff(old: "o", new: "")), "-o")
        expect(LineDiff.diff(old: "", new: "").isEmpty)
        // Too big for the LCS table: everything removed, then everything added.
        expectEqual(kinds(LineDiff.diff(old: "a\nb", new: "a\nc", maxCells: 1)), "-a|-b|+a|+c")
    }
    test("compact keeps context around changes and folds the rest") {
        let old = (1...20).map(String.init).joined(separator: "\n")
        let new = old.replacingOccurrences(of: "\n10\n", with: "\nten\n")
        let c = LineDiff.compact(LineDiff.diff(old: old, new: new), context: 2)
        expectEqual(kinds(c), "~| 8| 9|-10|+ten| 11| 12|~")
        expectEqual(c.first?.text, "⋯ 7 unchanged lines")
        expectEqual(LineDiff.compact([DiffLine(kind: .context, text: "a"), DiffLine(kind: .added, text: "b")], context: 0).count, 2)
        expectEqual(LineDiff.compact([DiffLine(kind: .context, text: "x"), DiffLine(kind: .context, text: "y"),
                                      DiffLine(kind: .added, text: "z")], context: 0).first?.text, "⋯ 2 unchanged lines")
        expect(LineDiff.compact([DiffLine(kind: .context, text: "x")]).isEmpty, "nothing changed: nothing to show")
        let withGap = LineDiff.compact([DiffLine(kind: .context, text: "x"), DiffLine(kind: .gap, text: "⋯"),
                                        DiffLine(kind: .added, text: "y")], context: 0)
        expectEqual(kinds(withGap), "~|~|+y")
        expectEqual(LineDiff.stats(c).added, 1)
        expectEqual(LineDiff.stats(c).removed, 1)
    }
    test("edit diffs per tool") {
        expectEqual(kinds(EditDiff.lines(toolName: "Edit", input: ["old_string": "a", "new_string": "b"])!), "-a|+b")
        expect(EditDiff.lines(toolName: "Edit", input: ["old_string": "a"]) == nil)
        let multi = EditDiff.lines(toolName: "MultiEdit", input: ["edits": [["old_string": "a", "new_string": "b"],
                                                                           ["old_string": "c", "new_string": "c"],
                                                                           ["old_string": "x", "new_string": "y"], ["new_string": "z"],
                                                                           ["old_string": "q"]]])!
        expectEqual(kinds(multi), "-a|+b|~|-x|+y|~|+z|~|-q")
        expect(EditDiff.lines(toolName: "MultiEdit", input: ["edits": [] as [Any]]) == nil)
        expect(EditDiff.lines(toolName: "MultiEdit", input: [:]) == nil)
        expectEqual(kinds(EditDiff.lines(toolName: "Write", input: ["content": "1\n2\n3"], writeCap: 2)!), "+1|+2|~")
        expect(EditDiff.lines(toolName: "Write", input: ["content": ""])!.isEmpty)
        expect(EditDiff.lines(toolName: "Write", input: [:]) == nil)
        expect(EditDiff.lines(toolName: "Bash", input: ["command": "ls"]) == nil)
    }
    test("transcript and pending requests carry diffs") {
        let box = Sandbox(); defer { box.cleanup() }
        let p = TranscriptParser(url: box.jsonl("t.jsonl", [
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "e", "name": "Edit",
                                                            "input": ["file_path": "/f", "old_string": "a", "new_string": "b"]]]]],
        ]))
        p.refresh()
        if case .tool(let call) = p.items[0].kind { expectEqual(call.diff.map(kinds), "-a|+b") } else { expect(false) }
        box.write("pending/req.1", #"{"session_id":"s","tool_name":"Edit","tool_input":{"file_path":"/f","old_string":"a","new_string":"b"}}"#)
        box.write("pending/req.2", #"{"session_id":"w","tool_name":"Write","tool_input":{"content":"x"}}"#)
        box.write("pending/req.3", #"{"session_id":"n","tool_name":"Bash"}"#)
        let reqs = PendingRequests.load()
        expectEqual(reqs["s"]?.tool.summary, "/f")
        expectEqual(reqs["s"]?.tool.diff.map(kinds), "-a|+b")
        expect(reqs["w"]?.tool.summary.contains("content") == true, "no file path: the full request stays")
        expectEqual(reqs["n"]?.tool.summary, "")
        expect(reqs["n"]?.tool.diff == nil)
    }
}
