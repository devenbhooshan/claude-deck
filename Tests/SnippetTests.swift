import Foundation

func snippetTests() {
    let crisp = Snippet(id: "c", name: "Short and crisp!", text: "Keep replies short and crisp.")
    let dashes = Snippet(id: "d", name: "no em dashes", text: "No em dashes.\n", scope: .session("lead"))
    let other = Snippet(id: "o", name: "Ask less", text: "Don't ask what we can decide.", scope: .session("api"))

    test("snippets: names become /s commands, scope decides where they show") {
        expectEqual(crisp.command, "/s short-and-crisp")
        expectEqual(Snippet.slug("  ** "), "snippet")
        expect(crisp.applies(to: nil) && crisp.applies(to: "lead"))
        expect(dashes.applies(to: "lead") && !dashes.applies(to: "api") && !dashes.applies(to: nil))
        let library = SnippetLibrary(snippets: [crisp, dashes, other])
        expectEqual(library.available(for: "lead").map(\.id), ["d", "c"])
        expectEqual(library.available(for: nil).map(\.id), ["c"])
        let rows = library.commands(for: "lead")
        expectEqual(rows.map(\.command), ["/s no-em-dashes", "/s short-and-crisp", "/snippets"])
        expectEqual(rows.map(\.source), ["Snippet · this session", "Snippet", "Deck"])
        expectEqual(rows[0].kind, .snippet)
        expectEqual(rows[0].insert, "No em dashes.\n")
        expectEqual(rows[0].description, "No em dashes. ")
        expectEqual(rows[2].kind, .action)
        expectEqual(rows[2].insert, nil)
    }
    test("snippets: typed as /s name in the / menu") {
        expectEqual(CommandCatalog.query(in: "/s "), "s ")
        expectEqual(CommandCatalog.query(in: "/s sho"), "s sho")
        expect(CommandCatalog.query(in: "/s short and") == nil)
        expect(CommandCatalog.query(in: "/sx y") == nil)
        let rows = SnippetLibrary(snippets: [crisp, dashes]).commands(for: "lead")
        expectEqual(CommandCatalog.matches("s sho", in: rows).map(\.command), ["/s short-and-crisp"])
        expectEqual(CommandCatalog.matches("crisp", in: rows).map(\.command), ["/s short-and-crisp"])
        expectEqual(CommandCatalog.kind(of: "/snippets"), .send)  // never sent: the menu row opens the sheet
    }
    test("snippets: added to every message in one session") {
        var library = SnippetLibrary(snippets: [crisp, dashes, other])
        expectEqual(library.prepend("hi", for: "lead"), "hi")
        library.setEveryMessage("lead", "d", on: true)
        library.setEveryMessage("lead", "c", on: true)
        library.setEveryMessage("lead", "o", on: true)  // another session's snippet doesn't apply here
        expectEqual(library.standing(for: "lead").map(\.id), ["c", "d"])
        expectEqual(library.prepend("ship it", for: "lead"), "Keep replies short and crisp.\nNo em dashes.\n\nship it")
        expectEqual(library.prepend("", for: "lead"), "Keep replies short and crisp.\nNo em dashes.")
        expectEqual(library.prepend("/compact", for: "lead"), "/compact")
        expectEqual(library.prepend("hi", for: "api"), "hi")
        library.setEveryMessage("lead", "c", on: false)
        expectEqual(library.everyMessage["lead"], ["d", "o"])
        library.setEveryMessage("api", "o", on: true)
        library.delete("o")
        expectEqual(library.everyMessage, ["lead": ["d"]])
        expectEqual(library.snippets.map(\.id), ["c", "d"])
        library.setEveryMessage("lead", "d", on: false)
        expectEqual(library.everyMessage, [:])
        // A blank snippet adds nothing.
        library.save(Snippet(id: "b", name: "blank", text: "  "))
        library.setEveryMessage("x", "b", on: true)
        expectEqual(library.prepend("hi", for: "x"), "hi")
    }
    test("snippets: saved, edited and read back from snippets.json") {
        let box = Sandbox(); defer { box.cleanup() }
        Snippets.dir = box.root.appendingPathComponent("support")
        expectEqual(Snippets.load(), SnippetLibrary())
        var library = SnippetLibrary()
        library.save(crisp)
        library.save(dashes)
        library.save(Snippet(id: "c", name: "Crisp", text: "Be brief."))
        library.setEveryMessage("lead", "c", on: true)
        Snippets.save(library)
        expectEqual(Snippets.load(), library)
        expectEqual(Snippets.load().snippets.map(\.name), ["Crisp", "no em dashes"])
        let json = try String(contentsOf: Snippets.fileURL, encoding: .utf8)
        expect(json.contains(#""scope" : "global""#) && json.contains(#""scope" : "lead""#), json)
        // Written by hand: missing ids and scopes are filled in; a damaged file reads as empty.
        box.write("support/snippets.json", #"{"snippets":[{"name":"n","text":"t"}]}"#)
        let loaded = Snippets.load()
        expectEqual(loaded.snippets.map(\.scope), [.global])
        expect(!loaded.snippets[0].id.isEmpty)
        expectEqual(loaded.everyMessage, [:])
        box.write("support/snippets.json", "{}")
        expectEqual(Snippets.load(), SnippetLibrary())
        box.write("support/snippets.json", "{not json")
        expectEqual(Snippets.load(), SnippetLibrary())
    }
}
