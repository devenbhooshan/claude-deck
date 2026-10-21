import Foundation

/// A Claude Code background shell's command line around `command`.
private func shell(_ command: String) -> String {
    "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval '\(command)' < /dev/null && pwd -P >| /tmp/claude-ab-cwd"
}

/// Starts `command` the way Claude Code runs a background task: a shell leading its own process group.
private func spawnTask(_ command: String) -> pid_t {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)
    let script = "true /shell-snapshots/ && eval '\(command)' < /dev/null && pwd -P >| /dev/null"
    let words: [String] = ["/bin/zsh", "-c", script]
    let args: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    posix_spawn(&pid, "/bin/zsh", nil, &attr, args, environ)
    posix_spawnattr_destroy(&attr)
    return pid
}

func backgroundTaskTests() {
    test("the command inside Claude Code's shell") {
        expectEqual(BackgroundTasks.command(fromShell: shell("npm run dev")), "npm run dev")
        expectEqual(BackgroundTasks.command(fromShell: shell(#"echo '\''hi'\'' > x"#)), "echo 'hi' > x")
        expect(BackgroundTasks.command(fromShell: "/bin/zsh -c ls") == nil)
        expect(BackgroundTasks.command(fromShell: "zsh /shell-snapshots/ && eval 'x") == nil)
        expect(BackgroundTasks.command(fromShell: "/shell-snapshots/ ' < /dev/null && eval 'x") == nil)
    }
    test("tidied for display") {
        expectEqual(BackgroundTasks.tidy(#"export PATH="$HOME/.rbenv/bin:$PATH"; tail -f /dev/null | bin/dev > /tmp/dev.log 2>&1"#), "bin/dev")
        expectEqual(BackgroundTasks.tidy("export A=1; export B='x y';  npm test 2>&1"), "npm test")
        expectEqual(BackgroundTasks.tidy("make watch >> build.log"), "make watch")
        expectEqual(BackgroundTasks.tidy("  ./run.sh &> out.txt "), "./run.sh")
        expectEqual(BackgroundTasks.tidy("> x"), "> x")
    }
    test("servers and watchers") {
        for c in ["bin/dev", "tail -f /dev/null | bin/dev > log", "bin/rails server", "rails s -p 3001", "npm run dev", "pnpm dev",
                  "yarn start", "bun run watch", "npx vite", "next dev", "uvicorn app:app --reload", "python3 -m http.server 8000",
                  "python manage.py runserver", "docker compose up", "tsc -p . --watch", "tail -f log/development.log", "cd web && npm start"] {
            expect(BackgroundTasks.isServer(c), c)
        }
        for c in ["npm test", "make", "pytest -x", "sleep 60", "tail -f /dev/null | ./import.sh", "./scripts/deploy.sh", "npm run build"] {
            expect(!BackgroundTasks.isServer(c), c)
        }
    }
    test("ps elapsed times") {
        expectEqual(BackgroundTasks.seconds(fromElapsed: "05:10"), 310)
        expectEqual(BackgroundTasks.seconds(fromElapsed: "18:58:05"), 68285)
        expectEqual(BackgroundTasks.seconds(fromElapsed: "08-00:32:47"), 8 * 86400 + 1967)
        expect(BackgroundTasks.seconds(fromElapsed: "x-01:00") == nil)
        expect(BackgroundTasks.seconds(fromElapsed: "1:2:3:4") == nil)
        expect(BackgroundTasks.seconds(fromElapsed: "aa:10") == nil)
        expect(BackgroundTasks.seconds(fromElapsed: "") == nil)
    }
    test("parsing the process list") {
        let now = Date(timeIntervalSince1970: 100_000)
        let ps = """
          94532 23277 94532    18:58:05 \(shell("tail -f /dev/null | bin/dev > /tmp/dev.log 2>&1"))
          94533 94532 94532    18:58:05 tail -f /dev/null
          700   23277   700       01:00 \(shell("make test"))
          800   23277   700       02:00 \(shell("child of a group"))
          900     555   900       bad   \(shell("x"))
          901 555
        """
        let tasks = BackgroundTasks.parse(ps, now: now)
        expectEqual(tasks.keys.sorted(), [23277])
        let mine = tasks[23277]!
        expectEqual(mine.map(\.command), ["bin/dev", "make test"]) // oldest first
        expectEqual(mine[0].started, now.addingTimeInterval(-68285))
        expect(mine[0].isServer && !mine[1].isServer)
        expectEqual(mine[0].id, 94532)
    }
    test("finding and stopping a real task") {
        let pid = spawnTask("sleep 30")
        defer { kill(-pid, SIGKILL); waitpid(pid, nil, 0) }
        expect(waitUntil(3) { BackgroundTasks.snapshot()[getpid()]?.contains { $0.pid == pid } == true }, "found under its parent")
        let task = BackgroundTasks.snapshot()[getpid()]!.first { $0.pid == pid }!
        expectEqual(task.command, "sleep 30")
        expect(BackgroundTasks.stop(task))
        waitpid(pid, nil, 0)
        expect(!BackgroundTasks.stop(task), "already gone: nothing is signalled")
        // One that ignores SIGTERM is killed after the grace period.
        let stubborn = spawnTask("trap \"\" TERM; while true; do sleep 0.1; done")
        defer { kill(-stubborn, SIGKILL); waitpid(stubborn, nil, 0) }
        expect(waitUntil(3) { BackgroundTasks.snapshot()[getpid()]?.contains { $0.pid == stubborn } == true })
        let t2 = BackgroundTasks.snapshot()[getpid()]!.first { $0.pid == stubborn }!
        expect(BackgroundTasks.stop(t2, grace: 0.3))
        waitpid(stubborn, nil, 0)
        expect(kill(-stubborn, 0) != 0, "gone after SIGKILL")
    }
}
