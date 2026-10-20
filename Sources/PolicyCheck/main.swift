import Foundation

// deck-policy: Claude Code's PreToolUse hook. Reads the hook's JSON on stdin and prints a
// decision when one of Deck's policies matches; prints nothing otherwise. Built by build.sh
// together with Core/Policies.swift and bundled in Deck.app.
if let out = Policies.check(FileHandle.standardInput.readDataToEndOfFile()) {
    FileHandle.standardOutput.write(out)
}
