import AppKit

let suites: [(String, () -> Void)] = [
    ("Models", modelTests), ("Format & palette", formatTests), ("Navigation", navTests),
    ("Terminal matching", terminalTests), ("Safety", safetyTests), ("Markdown", markdownTests), ("Export", exportTests),
    ("Notifications", notificationTests), ("Transcript writer", writerTests), ("File watcher", watcherTests),
    ("Paths", pathTests), ("Tail reader", tailTests), ("Transcript parser", parserTests),
    ("Session loading", loaderTests), ("Fresh records", recordTests), ("Attachment purge", purgeTests), ("Permission requests", pendingTests), ("Attachments", attachmentTests),
    ("Tool style", toolStyleTests), ("Renderer", rendererTests), ("Text view", textViewTests),
    ("Skills", skillTests), ("Slash commands", commandTests), ("Command kinds", commandKindTests), ("Plan usage", planUsageTests), ("Diffs", diffTests), ("claude command", claudeCLITests),
    ("Activity", activityTests), ("Activity index", activityIndexTests), ("Activity summaries", activitySummaryTests), ("Search", searchTests),
    ("Background tasks", backgroundTaskTests), ("Unread replies", unreadTests), ("Policies", policyTests), ("Policy history & suggestions", policyHistoryTests), ("Policy files & hook", policyIOTests), ("File links", fileLinkTests),
]
for (name, run) in suites {
    print("• \(name)")
    run()
}
print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
