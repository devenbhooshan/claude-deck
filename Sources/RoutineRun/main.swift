import Foundation

// deck-routine: what launchd runs on a routine's schedule (`deck-routine run <id>`). Runs the
// routine once with `claude -p` and records the run for Deck. Deck also uses it to continue a
// run with your message (`deck-routine reply <id> <run> <message>`), and anyone can list, show,
// update or delete routines from a terminal. Built by build.sh together with Core/Routines.swift
// and bundled in Deck.app.
let args = CommandLine.arguments
if args.count == 3, args[1] == "run" {
    Routines.run(args[2])
} else if args.count == 5, args[1] == "reply" {
    Routines.reply(args[2], run: args[3], message: args[4])
} else {
    let result = Routines.command(Array(args.dropFirst()))
    let out = result.status == 0 ? FileHandle.standardOutput : FileHandle.standardError
    if !result.output.isEmpty { out.write(Data((result.output + "\n").utf8)) }
    exit(result.status)
}
