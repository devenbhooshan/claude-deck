#!/usr/bin/env python3
"""Regenerates docs/screenshots with made-up data.

Runs a copy of the built app with its own bundle id and a temporary home folder, so it can't see
or change your real sessions, routines or preferences. It comes to the front for a few seconds per shot.

    ./build.sh && python3 scripts/screenshots.py
"""
import json, os, shutil, subprocess, sys, tempfile, time, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILT = os.path.join(ROOT, "build/Claude Deck.app")
DEMO_ID = "com.devenbhooshan.claudedeck.demo"
BUNDLE = APP = None
OUT = os.path.join(ROOT, "docs/screenshots")
COCOA = 978307200  # JSONEncoder's dates count from 2001.

home = claude = deck = routines = None
sleepers = []


def new_home():
    """Each shot gets its own: Deck only reopens its window on the first launch in a home."""
    global home, claude, deck, routines
    home = tempfile.mkdtemp(prefix="deck-demo-")
    claude = os.path.join(home, ".claude")
    deck = os.path.join(home, "Library/Application Support/ClaudeDeck")
    routines = os.path.join(deck, "routines")


def clean_up(app):
    os.kill(app, 9)
    time.sleep(1)
    subprocess.run(["defaults", "delete", DEMO_ID], capture_output=True)
    for s in sleepers:
        s.terminate()
    sleepers.clear()
    shutil.rmtree(home, ignore_errors=True)


def iso(ago):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - ago))


def user(text, ago):
    return {"type": "user", "uuid": str(uuid.uuid4()), "timestamp": iso(ago), "message": {"role": "user", "content": text}}


def say(text, ago):
    return {"type": "assistant", "uuid": str(uuid.uuid4()), "timestamp": iso(ago),
            "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def tool(name, input, result, ago):
    id = "t" + uuid.uuid4().hex[:8]
    call = {"type": "assistant", "uuid": str(uuid.uuid4()), "timestamp": iso(ago),
            "message": {"role": "assistant", "content": [{"type": "tool_use", "id": id, "name": name, "input": input}]}}
    if result is None:
        return [call]
    return [call, {"type": "user", "uuid": str(uuid.uuid4()), "timestamp": iso(ago - 2),
                   "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": id, "content": result}]}}]


def session(name, folder, title, records, status="idle", waiting=None):
    sid = str(uuid.uuid4())
    cwd = os.path.join(home, "code", folder)
    os.makedirs(cwd, exist_ok=True)
    sleeper = subprocess.Popen(["sleep", "600"])
    sleepers.append(sleeper)
    now = time.time() * 1000
    with open(os.path.join(claude, "sessions", f"{sleeper.pid}.json"), "w") as f:
        json.dump({"pid": sleeper.pid, "sessionId": sid, "cwd": cwd, "startedAt": now - 3_600_000, "kind": "interactive",
                   "entrypoint": "cli", "name": name, "status": status, "waitingFor": waiting,
                   "updatedAt": now, "statusUpdatedAt": now}, f)
    folder = os.path.join(claude, "projects", "".join(c if c.isalnum() else "-" for c in cwd))
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{sid}.jsonl")
    write(path, [{"type": "ai-title", "aiTitle": title}] + records)
    return sid, path


def write(path, records, mode="w"):
    with open(path, mode) as f:
        for r in records:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")  # Deck scans for Claude Code's compact form.


def setup(prompt=True):
    os.makedirs(os.path.join(claude, "sessions"))
    os.makedirs(os.path.join(claude, "projects"))
    os.makedirs(os.path.join(routines, "runs"))

    main, _ = session("orbit-api", "orbit-api", "Fix the flaky checkout test", [
        user("the checkout test fails about one run in five on CI. can you find out why?", 900),
        say("I'll run it repeatedly first, so we know the failure is real before changing anything.", 890),
        *tool("Bash", {"command": "npm test -- checkout --repeat 20", "description": "Run the checkout test 20 times"},
              "Tests: 4 failed, 16 passed\n  expected order.total to equal 4200, received 0", 880),
        *tool("Read", {"file_path": os.path.join(home, "code/orbit-api/src/checkout.ts")}, "export async function placeOrder(cart) {", 860),
        say("The total is read before the payment write finishes, so it's a race in `placeOrder`.", 850),
        *tool("Edit", {"file_path": os.path.join(home, "code/orbit-api/src/checkout.ts"),
                       "old_string": "  savePayment(order)\n  return order.total",
                       "new_string": "  await savePayment(order)\n  return order.total"}, "ok", 840),
        *tool("Bash", {"command": "npm test -- checkout --repeat 50", "description": "Run it 50 times to confirm"},
              "Tests: 50 passed", 800),
        say("""Fixed: **50 runs in a row pass**, up from about 4 in 5.

The cause was a missing `await`, so the total was read before the payment was saved:

```ts
await savePayment(order)
return order.total
```

> Two other callers of `savePayment` have the same bug: `refunds.ts` and `invoices.ts`.

Should I fix those too?""", 790),
        {"type": "system", "subtype": "turn_duration", "durationMs": 95000, "uuid": str(uuid.uuid4()), "timestamp": iso(788)},
    ])
    waiting, _ = session("orbit-web", "orbit-web", "Move billing to the new API", [
        user("run the billing migration on staging", 300),
        say("Running it now.", 290),
        *tool("Bash", {"command": "npm run migrate -- --env staging", "description": "Migrate staging"}, None, 280),
    ], status="waiting" if prompt else "busy", waiting="permission" if prompt else None)
    pending = os.path.join(home, "Library/Caches/com.devenbhooshan.claudedeck/pending")
    os.makedirs(pending)
    with open(os.path.join(pending, "demo.json"), "w") as f:
        json.dump({"session_id": waiting, "tool_name": "Bash",
                   "tool_input": {"command": "npm run migrate -- --env staging"}}, f)
    session("orbit-docs", "orbit-docs", "Write the v2 upgrade guide", [
        user("draft the upgrade guide for v2", 200),
        say("Reading the changelog first.", 190),
    ], status="busy")
    _, reply = session("orbit-mobile", "orbit-mobile", "Crash on the settings screen", [
        user("why does settings crash on Android 15?", 600),
    ])

    routine = {"id": "r-digest", "name": "Morning CI digest", "folder": os.path.join(home, "code/orbit-api"),
               "prompt": "Check last night's CI runs and tell me what needs me.",
               "schedule": {"kind": "daily", "hour": 9, "minute": 0, "everyHours": 2, "weekdays": [2, 3, 4, 5, 6]},
               "access": "readOnly", "model": "", "timeoutMinutes": 30, "enabled": True, "created": time.time() - COCOA - 864000}
    with open(os.path.join(routines, "r-digest.json"), "w") as f:
        json.dump(routine, f)
    for days, status, text in [(0.01, "succeeded", "All green overnight: 42 runs passed."),
                               (1, "succeeded", "All green overnight: 38 runs passed."),
                               (2, "failed", "The nightly build stopped: the staging database was unreachable.")]:
        start = time.time() - COCOA - days * 86400
        name = time.strftime("%Y-%m-%dT090000", time.localtime(time.time() - days * 86400))
        with open(os.path.join(routines, "runs", f"r-digest__{name}.json"), "w") as f:
            json.dump({"id": name, "routine": "r-digest", "started": start, "finished": start + 95, "status": status,
                       "result": text, "denied": 0, "cost": 0.18, "turns": 6}, f)
    return main, reply


def finish(reply):
    """Things that happen once Deck is watching: a new reply and a routine run finishing."""
    write(reply, [say("It's a null `userPrefs` on first launch. The fix is one line; want it?", 1)], "a")
    now = time.time() - COCOA
    name = time.strftime("%Y-%m-%dT%H%M%S")
    path = os.path.join(routines, "runs", f"r-digest__{name}.json")
    with open(path + ".tmp", "w") as f:
        json.dump({"id": name, "routine": "r-digest", "started": now - 118, "finished": now, "status": "succeeded",
                   "result": "One thing needs you: the deploy job on orbit-api has failed twice since midnight.",
                   "denied": 0, "cost": 0.21, "turns": 7}, f)
    os.rename(path + ".tmp", path)


def windows(helper, pid):
    out = subprocess.run([helper, str(pid)], capture_output=True, text=True).stdout
    return [tuple(int(x) for x in line.split()) for line in out.splitlines()]


def biggest(helper, pid):
    for _ in range(30):  # The window can take a moment to reach the screen.
        shown = [w for w in windows(helper, pid) if w[3] == 0]
        if shown:
            return max(shown, key=lambda w: w[1] * w[2])[0]
        time.sleep(0.5)
    raise SystemExit("Deck's window never appeared")


def capture(id, name):
    subprocess.run(["screencapture", "-x", "-o", "-l", str(id), os.path.join(OUT, name)], check=True)


def crop(name, x, y, width, height):
    """Pixels. The main window is cropped because its sidebar sits under the toolbar in this copy."""
    path = os.path.join(OUT, name)
    subprocess.run(["sips", "-c", str(height), str(width), "--cropOffset", str(y), str(x), path],
                   check=True, capture_output=True)


def launch(*args):
    """Through `open`: macOS only brings a second launch to the front if LaunchServices started it."""
    subprocess.run(["open", "-n", BUNDLE, "--env", f"CFFIXED_USER_HOME={home}", "--env", f"HOME={home}", "--args",
                    "-dockShown", "YES", "-dockExpanded", "NO", *args], check=True)
    time.sleep(1)
    return int(subprocess.run(["pgrep", "-nf", APP], capture_output=True, text=True).stdout)


def shot(helper, start, take, prompt=False):
    new_home()
    session_id, reply = setup(prompt)
    app = launch(*start(session_id))
    try:
        time.sleep(5)
        finish(reply)
        time.sleep(6)
        take(app)
    finally:
        clean_up(app)


def main():
    os.makedirs(OUT, exist_ok=True)
    build = tempfile.mkdtemp(prefix="deck-demo-tools-")
    helper = os.path.join(build, "windows")
    global BUNDLE, APP
    BUNDLE = os.path.join(build, "Claude Deck Demo.app")
    APP = os.path.join(BUNDLE, "Contents/MacOS/ClaudeDeck")
    shutil.copytree(BUILT, BUNDLE, symlinks=True)
    subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", DEMO_ID, os.path.join(BUNDLE, "Contents/Info.plist")], check=True)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", BUNDLE], check=True, capture_output=True)
    subprocess.run(["swiftc", "-o", helper, os.path.join(ROOT, "scripts/windows.swift")], check=True)

    def panels_shot(app):
        panels = {340: "dock.png", 360: "routine-popup.png"}
        for id, width, height, layer in windows(helper, app):
            if layer > 0 and width in panels:
                capture(id, panels[width])

    try:
        shot(helper, lambda id: ["--open", id], lambda app: capture(biggest(helper, app), "session.png"))
        shot(helper, lambda id: ["--open", id], panels_shot, prompt=True)
        shot(helper, lambda id: ["--policies"], lambda app: capture(biggest(helper, app), "policies.png"))
        crop("session.png", 760, 112, 1640, 960)
        crop("policies.png", 561, 141, 1278, 1279)
    finally:
        shutil.rmtree(build, ignore_errors=True)


main()
