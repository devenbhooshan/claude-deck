import Foundation

// deck-routine: what launchd runs on a routine's schedule (`deck-routine run <id>`). Runs the
// routine once with `claude -p` and records the run for Deck. Built by build.sh together with
// Core/Routines.swift and bundled in Deck.app.
let args = CommandLine.arguments
guard args.count == 3, args[1] == "run" else {
    FileHandle.standardError.write(Data("usage: deck-routine run <routine id>\n".utf8))
    exit(2)
}
Routines.run(args[2])
