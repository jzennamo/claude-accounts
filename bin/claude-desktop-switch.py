#!/usr/bin/env python3
"""Switch the Claude desktop app between saved sign-ins (called as `claude-acct desktop ...`).

The desktop app's sign-in is its claude.ai cookies + web storage + three keys in config.json.
A switch quits Claude, snapshots the current sign-in under its profile name, restores the
target's (or clears it, for `new`), and reopens Claude. Everything else in the app's folder
(settings, Code sessions, worktrees) is untouched and shared between accounts.

  list [--json]        saved profiles; * marks the one signed in now
  name <name>          name the account signed in now (stored at the next switch)
  switch <name>        switch to a saved profile
  new                  save the current sign-in, then reopen Claude signed out to add another account
  forget <name>        delete a saved profile (moves it to the Trash)
  setup <name>...      sign each named account in once (names as in `claude-acct list`), one after another

Profiles live in ~/Library/Application Support/ClaudeUsage/desktop-profiles (mode 700). The first
switch also keeps a full copy of the original state in .original-<time>/, and each switch keeps the
files it replaced in .last-replaced/.
"""
import json, os, re, shutil, subprocess, sys, time

HOME = os.path.expanduser("~")
APP_DIR = os.environ.get("CLAUDE_DESKTOP_DIR", HOME + "/Library/Application Support/Claude")
STORE = os.environ.get("CLAUDE_DESKTOP_PROFILES", HOME + "/Library/Application Support/ClaudeUsage/desktop-profiles")
NO_APP = os.environ.get("CLAUDE_DESKTOP_NOAPP") == "1"   # tests: never quit or launch the real app
BUNDLE = "com.anthropic.claudefordesktop"
PATHS = ["Cookies", "Cookies-journal", "Local Storage", "Session Storage", "IndexedDB"]
KEYS = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
NAMES = os.path.join(STORE, "names.json")  # accountUuid -> profile name
NAME_RE = re.compile(r"^[A-Za-z0-9._@+-]+$")


def die(msg):
    print("error: " + msg, file=sys.stderr); sys.exit(1)


def load(path, default):
    try:
        with open(path) as f: return json.load(f)
    except (OSError, ValueError): return default


def dump(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f: json.dump(obj, f, indent=1)
    os.replace(tmp, path)


def cfg_path(): return os.path.join(APP_DIR, "config.json")
def current_uuid(): return load(cfg_path(), {}).get("lastKnownAccountUuid")
def names(): return load(NAMES, {})


def profiles():
    out = {}
    if os.path.isdir(STORE):
        for n in sorted(os.listdir(STORE)):
            meta = load(os.path.join(STORE, n, "meta.json"), None)
            if not n.startswith(".") and meta: out[n] = meta
    return out


_cli = None
def cli_accounts():
    """accountUuid -> (name, email) for the Claude Code accounts (claude-acct list), by whose token each holds."""
    global _cli
    if _cli is not None: return _cli
    sys.dont_write_bytecode = True
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    from claude_acct_id import ident
    out = {}
    root = os.path.join(HOME, ".claude-accounts")
    dirs = [("default", os.path.join(HOME, ".claude"))] + [
        (n, os.path.join(root, n)) for n in (sorted(os.listdir(root)) if os.path.isdir(root) else [])
        if os.path.isdir(os.path.join(root, n))]
    for n, d in dirs:
        i = ident(d); u = i.get("uuid")
        if u and (u not in out or out[u][0] == "default"): out[u] = (n, i.get("email"))
    _cli = out
    return out


def email_for(uuid): return cli_accounts().get(uuid, (None, None))[1]


def name_for(uuid):
    if not uuid: return None
    if uuid in names(): return names()[uuid]
    for n, m in profiles().items():
        if m.get("uuid") == uuid: return n
    return cli_accounts().get(uuid, (None,))[0]  # same account as a Claude Code one: use its name


def running():
    r = subprocess.run(["pgrep", "-f", "Claude.app/Contents/MacOS/Claude( |$)"], capture_output=True, text=True)
    return [p for p in r.stdout.split() if p.strip()]


def inside_claude_app():
    """True if this process descends from the Claude desktop app (quitting it would kill us mid-switch)."""
    pid = os.getppid()
    for _ in range(12):
        if pid <= 1: return False
        r = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        if not r: return False
        ppid, comm = r.split(None, 1)
        if "Claude.app/" in comm: return True
        pid = int(ppid)
    return False


def quit_app():
    if NO_APP or not running(): return
    if inside_claude_app():
        die("this runs inside the Claude app, and switching quits it. Use the menu bar or Terminal.app instead.")
    # NSRunningApplication.terminate = a normal Cmd-Q (Claude saves its cookies on the way out).
    subprocess.run(["osascript", "-l", "JavaScript", "-e",
                    f"ObjC.import('AppKit'); var a=$.NSRunningApplication.runningApplicationsWithBundleIdentifier('{BUNDLE}');"
                    "for (var i=0;i<a.count;i++) a.objectAtIndex(i).terminate;"], capture_output=True, timeout=20)
    for sig_wait in (45, 20):
        t = time.time()
        while running() and time.time() - t < sig_wait: time.sleep(0.5)
        if not running(): break
        subprocess.run(["pkill", "-TERM", "-f", "Claude.app/Contents/MacOS/Claude( |$)"])
    if running(): die("Claude did not quit (a 'quit anyway?' dialog may be open). Nothing was changed.")
    time.sleep(1.5)  # let helpers release the cookie/leveldb files


def launch():
    if not NO_APP: subprocess.run(["open", "-b", BUNDLE])


def rm(p):
    if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p)
    elif os.path.lexists(p): os.remove(p)


def copy(src, dst):
    if os.path.isdir(src): shutil.copytree(src, dst, symlinks=True)
    elif os.path.exists(src): shutil.copy2(src, dst)


def first_backup():
    if any(n.startswith(".original-") for n in os.listdir(STORE)): return
    b = os.path.join(STORE, ".original-" + time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(b)
    for p in PATHS + ["config.json"]: copy(os.path.join(APP_DIR, p), os.path.join(b, p))


def snapshot(name, uuid):
    dst = os.path.join(STORE, name); tmp = dst + ".tmp"
    rm(tmp); os.makedirs(tmp)
    for p in PATHS: copy(os.path.join(APP_DIR, p), os.path.join(tmp, p))
    c = load(cfg_path(), {})
    dump(os.path.join(tmp, "meta.json"), {"uuid": uuid, "saved": time.strftime("%Y-%m-%d %H:%M:%S"),
                                          "config": {k: c[k] for k in KEYS if k in c}})
    old = dst + ".old"; rm(old)
    if os.path.exists(dst): os.rename(dst, old)
    os.rename(tmp, dst); rm(old)


def replace_live(src):
    """Set the app's sign-in to profile dir `src` (None = signed out). Old files go to .last-replaced."""
    keep = os.path.join(STORE, ".last-replaced"); rm(keep); os.makedirs(keep)
    for p in PATHS:
        live = os.path.join(APP_DIR, p)
        if os.path.lexists(live): shutil.move(live, os.path.join(keep, p))
        if src: copy(os.path.join(src, p), live)
    c = load(cfg_path(), None)
    if c is None: die("can't read " + cfg_path())
    shutil.copy2(cfg_path(), os.path.join(keep, "config.json"))
    for k in KEYS: c.pop(k, None)
    if src: c.update(load(os.path.join(src, "meta.json"), {}).get("config", {}))
    dump(cfg_path(), c)


def switch(target):
    profs = profiles()
    if target is not None and target not in profs: die(f"no saved desktop profile '{target}'")
    uuid = current_uuid()
    cur = name_for(uuid) or (f"account-{uuid[:8]}" if uuid else None)
    if target is not None and target == cur:
        launch(); print(f"already on {target}"); return
    os.makedirs(STORE, exist_ok=True); os.chmod(STORE, 0o700)
    quit_app()
    first_backup()
    if uuid:
        snapshot(cur, uuid)
        n = names(); n[uuid] = cur; dump(NAMES, n)
        print(f"saved current sign-in as '{cur}'")
    replace_live(os.path.join(STORE, target) if target else None)
    launch()
    print(f"switched to {target}" if target else "Claude reopened signed out: sign in with the other account "
          "(once); next time it's in the switcher")


def _line0():
    """One line from fd 0 without read-ahead (tests pipe answers that later bash prompts also read)."""
    b = b""
    while True:
        c = os.read(0, 1)
        if not c or c == b"\n": return b.decode().strip()
        b += c


def tty_input(prompt):
    if os.environ.get("CLAUDE_ACCT_TTY") == "/dev/stdin":  # tests
        print(prompt, end="", flush=True); return _line0()
    with open("/dev/tty", "r+") as t:
        t.write(prompt); t.flush()
        return t.readline().strip()


def wait_signed_in(timeout=900):
    t = time.time()
    while time.time() - t < timeout:
        u = current_uuid()
        if u: return u
        time.sleep(2)
    return None


def setup(wanted):
    """Sign the desktop app in to each named account once (matched to the Claude Code account of that name)."""
    cli = {n: (u, e) for u, (n, e) in cli_accounts().items()}
    for n in wanted:
        if not NAME_RE.match(n): die(f"bad name '{n}'")
        tu, te = cli.get(n, (None, None))
        have = {m.get("uuid") for m in profiles().values()} | {current_uuid()}
        if tu and tu in have:
            if tu == current_uuid():
                d = names(); d[tu] = n; os.makedirs(STORE, exist_ok=True); dump(NAMES, d)
            print(f"✓ {n} already in the desktop switcher"); continue
        if n in profiles() and not tu:
            print(f"✓ {n} already in the desktop switcher"); continue
        who = te or f"the account you want for '{n}'"
        while True:
            a = tty_input(f"\nPress return to sign the desktop app in as {who} ({n}), or s + return to skip: ")
            if a == "s": print(f"– {n} skipped"); break
            switch(None)
            print(f"Waiting for you to sign in as {who} in the Claude window…\n"
                  "  If it sends you to a browser that's signed in as someone else, copy the link into a private window.")
            u = wait_signed_in()
            if not u: print(f"✗ {n}: no sign-in within 15 min"); break
            if tu and u != tu:
                other = name_for(u) or email_for(u) or u[:8]
                print(f"✗ {n}: that signed in as '{other}', not {who}.")
                if tty_input("Try again? [Y/n] ").lower().startswith("n"): break
                continue
            if not tu and u in {m.get("uuid") for m in profiles().values()}:
                print(f"✗ {n}: that's the already-saved '{name_for(u)}'.")
                if tty_input("Try again? [Y/n] ").lower().startswith("n"): break
                continue
            d = names(); d[u] = n; dump(NAMES, d)
            print(f"✓ {n} signed in to the desktop app")
            break


def cmd_list(as_json):
    uuid = current_uuid(); cur = name_for(uuid)
    rows = [{"name": n, "uuid": m.get("uuid"), "saved": m.get("saved"), "current": m.get("uuid") == uuid}
            for n, m in profiles().items()]
    if uuid and not any(r["current"] for r in rows):
        rows.insert(0, {"name": cur or f"account-{uuid[:8]}", "uuid": uuid, "saved": None, "current": True,
                        "unnamed": cur is None})
    for r in rows: r["email"] = email_for(r["uuid"])
    if as_json: print(json.dumps(rows)); return
    for r in rows:
        print(("* " if r["current"] else "  ") + r["name"].ljust(18) + " " + (r["email"] or r["uuid"] or "")
              + ("" if r["saved"] else "  (not saved yet)"))


def main(a):
    if not a or a[0] in ("-h", "--help", "help"): print(__doc__); return
    c = a[0]
    if c == "list": cmd_list("--json" in a)
    elif c == "name":
        if len(a) < 2 or not NAME_RE.match(a[1]): die("usage: name <name>  (letters, digits, . _ @ + -)")
        uuid = current_uuid()
        if not uuid: die("the desktop app isn't signed in")
        old = name_for(uuid)
        if a[1] in profiles() and profiles()[a[1]].get("uuid") != uuid: die(f"'{a[1]}' is another account's profile")
        os.makedirs(STORE, exist_ok=True); os.chmod(STORE, 0o700)
        if old and old != a[1] and os.path.isdir(os.path.join(STORE, old)):
            os.rename(os.path.join(STORE, old), os.path.join(STORE, a[1]))
        n = names(); n[uuid] = a[1]; dump(NAMES, n); print(f"current desktop account is '{a[1]}'")
    elif c == "switch":
        if len(a) < 2: die("usage: switch <name>")
        switch(a[1])
    elif c == "new": switch(None)
    elif c == "setup":
        if len(a) < 2: die("usage: setup <name>...")
        setup(a[1:])
    elif c == "forget":
        if len(a) < 2 or a[1] not in profiles(): die("usage: forget <saved name>")
        if profiles()[a[1]].get("uuid") == current_uuid(): die("that's the account signed in now")
        shutil.move(os.path.join(STORE, a[1]), os.path.join(HOME, ".Trash", f"claude-desktop-{a[1]}-{int(time.time())}"))
        n = {k: v for k, v in names().items() if v != a[1]}; dump(NAMES, n); print(f"forgot {a[1]}")
    else: die("unknown command; see --help")


if __name__ == "__main__":
    main(sys.argv[1:])
