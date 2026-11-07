#!/usr/bin/env python3
"""Which account does a Claude Code config dir's keychain token really belong to?

`.claude.json`'s oauthAccount can be rewritten by other Claude processes (e.g. the desktop app's Code tab writes
its own account into ~/.claude.json), so the token is the source of truth. We ask /api/oauth/profile once per
access token and cache the answer (keyed by a hash of the token, never the token) in
~/Library/Application Support/ClaudeUsage/identity.json, shared with the menu bar app.
Falls back to .claude.json when the token is missing or expired (never refreshes it).

  claude_acct_id.py <config-dir> [email|uuid]     ("~/.claude" means the default account)
"""
import hashlib, json, os, subprocess, sys, time, urllib.request

HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, "Library/Application Support/ClaudeUsage/identity.json")
NO_KEYCHAIN = os.environ.get("CLAUDE_ACCT_NO_KEYCHAIN") == "1"   # tests


def service(d):
    d = os.path.normpath(d)
    if d == os.path.join(HOME, ".claude"): return "Claude Code-credentials"
    return "Claude Code-credentials-" + hashlib.sha256(d.encode()).hexdigest()[:8]


def json_ident(d):
    j = os.path.join(HOME, ".claude.json") if os.path.normpath(d) == os.path.join(HOME, ".claude") else os.path.join(d, ".claude.json")
    try: a = json.load(open(j)).get("oauthAccount") or {}
    except (OSError, ValueError): a = {}
    return {"email": a.get("emailAddress") or "", "uuid": a.get("accountUuid") or "", "source": "json"}


def load_cache():
    try: return json.load(open(CACHE))
    except (OSError, ValueError): return {}


def ident(d):
    if NO_KEYCHAIN: return json_ident(d)
    svc = service(d)
    r = subprocess.run(["security", "find-generic-password", "-a", os.environ.get("USER", ""), "-s", svc, "-w"],
                       capture_output=True, text=True)
    try: o = json.loads(r.stdout)["claudeAiOauth"]; tok = o["accessToken"]
    except (ValueError, KeyError, TypeError): return json_ident(d)
    h = hashlib.sha256(tok.encode()).hexdigest()[:16]
    c = load_cache().get(svc)
    if c and c.get("tok") == h: return {"email": c["email"], "uuid": c["uuid"], "source": "token"}
    if o.get("expiresAt", 0) / 1000 < time.time() + 30: return json_ident(d)
    req = urllib.request.Request("https://api.anthropic.com/api/oauth/profile", headers={
        "Authorization": "Bearer " + tok, "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-accounts/1.0"})
    try: p = json.load(urllib.request.urlopen(req, timeout=8))
    except Exception: return json_ident(d)
    a = p.get("account") or {}
    e, u = a.get("email") or a.get("email_address") or "", a.get("uuid") or ""
    if not u: return json_ident(d)
    cache = load_cache(); cache[svc] = {"tok": h, "email": e, "uuid": u}
    os.makedirs(os.path.dirname(CACHE), mode=0o700, exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f: json.dump(cache, f)
    os.replace(tmp, CACHE)
    return {"email": e, "uuid": u, "source": "token"}


if __name__ == "__main__":
    if len(sys.argv) < 2: print(__doc__); sys.exit(1)
    i = ident(os.path.expanduser(sys.argv[1]))
    print(i.get(sys.argv[2], "") if len(sys.argv) > 2 else json.dumps(i))
