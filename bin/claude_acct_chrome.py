#!/usr/bin/env python3
"""Claude in Chrome: one Chrome profile per Claude account (called as `claude-acct chrome ...`).

Chrome keeps each profile's cookies and extension storage separate, so a profile per account lets the
Claude in Chrome extension (and claude.ai) stay signed in to a different account in each, and you
switch by opening that profile's window. Nothing in your existing profiles is touched.

  list                      accounts with a Chrome profile; whether the extension is installed there
  profiles                  every Chrome profile (to pick one for `use`)
  add <name> [email]        create profile "Claude · <name>", open it on the extension's store page and claude.ai
  use <name> <profile-dir>  use an existing profile for <name> (e.g. `use personal Default`)
  open <name> [url]         open a window in that account's profile
  forget <name>             stop using a profile for <name> (the profile itself stays; remove it in Chrome)
  setup <name>...           `add` each account without a profile, one after another

The mapping lives in ~/.config/claude-accounts/chrome.json. Google Chrome only.
"""
import json, os, subprocess, sys

HOME = os.path.expanduser("~")
CHROME_DIR = os.environ.get("CLAUDE_ACCT_CHROME_DIR", HOME + "/Library/Application Support/Google/Chrome")
APP = "Google Chrome"
EXT_ID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"   # Claude (Claude in Chrome)
STORE = "https://chromewebstore.google.com/detail/" + EXT_ID
MAP = os.environ.get("CLAUDE_ACCT_CHROME_MAP", HOME + "/.config/claude-accounts/chrome.json")
NO_LAUNCH = os.environ.get("CLAUDE_ACCT_NO_LAUNCH") == "1"   # tests


def die(m): print("error: " + m, file=sys.stderr); sys.exit(1)


def load(p, d):
    try:
        with open(p) as f: return json.load(f)
    except (OSError, ValueError): return d


def save_map(m):
    os.makedirs(os.path.dirname(MAP), exist_ok=True)
    tmp = MAP + ".tmp"
    with open(tmp, "w") as f: json.dump(m, f, indent=1)
    os.replace(tmp, MAP)


def mapping(): return load(MAP, {})


def info_cache(): return load(os.path.join(CHROME_DIR, "Local State"), {}).get("profile", {}).get("info_cache", {})


def has_ext(pdir): return os.path.isdir(os.path.join(CHROME_DIR, pdir, "Extensions", EXT_ID))


def chrome_installed():
    return any(os.path.isdir(p) for p in ("/Applications/Google Chrome.app", HOME + "/Applications/Google Chrome.app"))


def open_profile(pdir, *urls):
    if NO_LAUNCH: print(f"  [would open Chrome profile {pdir}: {' '.join(urls)}]"); return
    subprocess.run(["open", "-na", APP, "--args", f"--profile-directory={pdir}", "--no-first-run", *urls])


def label(pdir):
    i = info_cache().get(pdir) or {}
    return i.get("name") or load(os.path.join(CHROME_DIR, pdir, "Preferences"), {}).get("profile", {}).get("name") or pdir


def cmd_list(as_json=False):
    rows = [{"name": n, "profile": d, "label": label(d), "exists": os.path.isdir(os.path.join(CHROME_DIR, d)),
             "extension": has_ext(d)} for n, d in sorted(mapping().items())]
    if as_json: print(json.dumps(rows)); return
    if not rows: print("no accounts have a Chrome profile yet — claude-acct chrome add <name> [email]"); return
    for r in rows:
        state = "extension installed" if r["extension"] else ("extension NOT installed" if r["exists"] else "profile missing")
        print(f"  {r['name']:14} {r['label']}  ({r['profile']}; {state})")


def cmd_profiles():
    used = {d: n for n, d in mapping().items()}
    for d, i in sorted(info_cache().items()):
        print(f"  {d:16} {i.get('name', ''):24} {i.get('user_name') or '':28} "
              f"{'Claude ext ✓' if has_ext(d) else ''}{'  → ' + used[d] if d in used else ''}")


def add(name, email=None):
    if not chrome_installed(): die("Google Chrome isn't installed")
    m = mapping()
    pdir = m.get(name) or "claude-" + name
    full = os.path.join(CHROME_DIR, pdir)
    if not os.path.isdir(full):
        os.makedirs(full)
        with open(os.path.join(full, "Preferences"), "w") as f:   # Chrome keeps this name for the new profile
            json.dump({"profile": {"name": f"Claude · {name}"}}, f)
    m[name] = pdir; save_map(m)
    print(f"Chrome profile '{label(pdir)}' ({pdir}) is for '{name}'. In the window that opens:")
    if not has_ext(pdir): print("  1. On the store tab: Add to Chrome (the Claude extension).")
    print(f"  {'2' if not has_ext(pdir) else '1'}. On the claude.ai tab: sign in{' as ' + email if email else ''}. If you get an e-mail link,"
          " right-click it ▸ Copy Link and paste it into this profile's window.")
    print("  Then open the Claude extension (puzzle-piece menu ▸ Claude; pin it) so it picks up the sign-in.")
    open_profile(pdir, *([] if has_ext(pdir) else [STORE]), "https://claude.ai/login")


def _line0():
    """One line from fd 0 without read-ahead (tests pipe answers that later bash prompts also read)."""
    b = b""
    while True:
        c = os.read(0, 1)
        if not c or c == b"\n": return b.decode().strip()
        b += c


def tty_input(prompt):
    if os.environ.get("CLAUDE_ACCT_TTY") == "/dev/stdin":
        print(prompt, end="", flush=True); return _line0()
    with open("/dev/tty", "r+") as t:
        t.write(prompt); t.flush(); return t.readline().strip()


def setup(names, emails):
    m = mapping()
    for n, e in zip(names, emails):
        if n in m and has_ext(m[n]):
            print(f"✓ {n} has Chrome profile '{label(m[n])}' with the extension"); continue
        if tty_input(f"\nPress return to set up Chrome for '{n}'{' (' + e + ')' if e else ''}, or s + return to skip: ") == "s":
            print(f"– {n} skipped"); continue
        add(n, e or None)
        tty_input("Press return when the extension is installed and you're signed in… ")
        d = mapping()[n]
        print(f"✓ {n}: extension installed in '{label(d)}'" if has_ext(d) else
              f"✗ {n}: the extension isn't installed in '{label(d)}' yet (re-run setup to finish)")


def main(a):
    if not a or a[0] in ("-h", "--help", "help"): print(__doc__); return
    c = a[0]
    if c == "list": cmd_list("--json" in a)
    elif c == "profiles": cmd_profiles()
    elif c == "add":
        if len(a) < 2: die("usage: add <name> [email]")
        add(a[1], a[2] if len(a) > 2 else None)
    elif c == "use":
        if len(a) < 3: die("usage: use <name> <profile-dir>   (see: claude-acct chrome profiles)")
        if not os.path.isdir(os.path.join(CHROME_DIR, a[2])): die(f"no Chrome profile folder '{a[2]}'")
        m = mapping(); m[a[1]] = a[2]; save_map(m); print(f"'{a[1]}' uses Chrome profile '{label(a[2])}'")
    elif c == "open":
        m = mapping()
        if len(a) < 2 or a[1] not in m: die("usage: open <name> [url]  (names: " + ", ".join(sorted(m)) + ")")
        open_profile(m[a[1]], *a[2:3])
    elif c == "profile-dir":   # for claude-acct: the profile folder for <name>, if any
        d = mapping().get(a[1]) if len(a) > 1 else None
        if d and os.path.isdir(os.path.join(CHROME_DIR, d)): print(d)
    elif c == "forget":
        m = mapping()
        if len(a) < 2 or a[1] not in m: die("usage: forget <name>")
        d = m.pop(a[1]); save_map(m); print(f"'{a[1]}' no longer uses Chrome profile {d} (the profile itself is unchanged)")
    elif c == "setup":
        pairs = [x.split("=", 1) if "=" in x else (x, "") for x in a[1:]]
        setup([p[0] for p in pairs], [p[1] for p in pairs])
    else: die("unknown command; see --help")


if __name__ == "__main__":
    main(sys.argv[1:])
