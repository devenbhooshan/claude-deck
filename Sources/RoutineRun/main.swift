import Foundation

// deck-routine: what launchd runs on a routine's schedule (`deck-routine run <id>`). Runs the
// routine once with `claude -p` and records the run for Deck. Deck also uses it to continue a
// run with your message (`deck-routine reply <id> <run> <message>`). Built by build.sh together
// with Core/Routines.swift and bundled in Deck.app.
let args = CommandLine.arguments
if args.count == 3, args[1] == "run" {
    Routines.run(args[2])
} else if args.count == 5, args[1] == "reply" {
    Routines.reply(args[2], run: args[3], message: args[4])
} else {
    FileHandle.standardError.write(Data("usage: deck-routine run <routine id> | reply <routine id> <run id> <message>\n".utf8))
    exit(2)
}
