---
name: claude-accounts
description: >
  Use several Claude accounts on one Mac without the sign-in e-mail every time, and watch every account's usage
  limits from the menu bar. Covers the `claude-acct` command (per-account Claude Code config dirs, a batch
  `setup` that signs in a whole list of accounts in turn, private-window sign-in so the browser's existing
  claude.ai login isn't reused), switching the Claude desktop app between saved logins, and the Claude Usage
  menu bar app (5-hour / weekly limits per account). Use this whenever the user wants to switch Claude
  accounts, has a work and a personal account, asks to stop signing in by e-mail, wants to see or track usage
  limits across accounts, mentions claude-acct, the Claude Usage menu, CLAUDE_CONFIG_DIR, or is stuck because
  an account "got added twice" / signed in as the wrong account -- even if they don't name this tool.
---

# claude-accounts

macOS only. Three pieces, installed by `./install.sh` from this folder:

| Piece | What it does |
|---|---|
| `claude-acct` (`~/.local/bin`) | One Claude Code config dir per account (`~/.claude-accounts/<name>`; `default` = `~/.claude`), each with its own keychain token that refreshes itself, so each account signs in once. |
| `claude-acct desktop …` | Switches the Claude **desktop app** by quitting it, swapping its saved claude.ai login (cookies, web storage, 3 keys in `config.json`) and reopening it. |
| `claude-acct chrome …` | **Claude in Chrome**: one Chrome profile per account ("Claude · <name>"), each with the extension signed in to that account. `open <name>` opens it; Claude Code sign-ins for that account then open there (one click, no e-mail). |
| Claude Usage menu bar app | Shows each Claude Code account's highest limit % in the menu bar, with 5-hour and weekly bars and reset times. The menu also has "Desktop app ▸" (switch the desktop app), "Open Claude Code as ▸", "Add account…" and "Sign in all my accounts…". |

## Commands

```bash
claude-acct setup [FILE] [--chrome] [--desktop] [--all]   # sign in every account in a list (asks for the list the first time)
claude-acct add <name> [email]         # one account
claude-acct list                       # name → e-mail
claude-acct <name> [claude args]       # run claude as that account
eval "$(claude-acct env <name>)"       # make this shell use that account
claude-acct rm <name>
claude-acct desktop list | switch <name> | new | name <name> | forget <name> | setup <name>...
claude-acct chrome list | profiles | add <name> [email] | use <name> <profile-dir> | open <name> [url] | forget <name>
claude-usage --dump                    # print every account's limits (what the menu shows)
```

List file (`~/.config/claude-accounts/accounts`, see `accounts.example`): `<name> <email>` per line.
`setup` skips accounts already signed in with the right e-mail, so it is safe to re-run.

## How to help

- To add accounts, point the user to `claude-acct setup` (or the menu's **Sign in all my accounts…**). It
  is interactive (waits for return, opens a private browser window), so the **user runs it in Terminal**;
  don't run it yourself through a non-interactive shell.
- **Never run `claude-acct desktop switch|new|setup` (or `setup --desktop`) from inside the Claude desktop
  app.** It quits the app, which ends your own session; `setup --desktop` refuses to run there. Tell the user
  to use the menu or Terminal instead.
- Read state with `claude-acct list`, `claude-acct desktop list` and `claude-usage --dump`. Never print
  tokens: they are in the login keychain (`Claude Code-credentials[-<sha256(dir)[:8]>]`) and in the desktop
  profile folder; check them with `security find-generic-password -s … >/dev/null` (exit status), not `-w`.

## Troubleshooting

| Symptom | Cause → fix |
|---|---|
| The same account was added several times | The browser was already signed in to claude.ai, so it approved that account again. `add`/`setup` now use a private window and remove a sign-in that's a duplicate or the wrong e-mail. For an e-mail link, **copy** it into the private window (clicking opens the normal browser). |
| Desktop switcher shows one account | Each desktop account needs one sign-in through `desktop new`/`setup`. If it came back as the same account, the desktop sign-in went through a browser signed in as that account: use "Continue with Google" with the other account, or paste the link into a private window. |
| Claude in Chrome is signed in to the wrong account | Each profile holds one login: open that account's profile (menu ▸ Claude in Chrome), sign out of claude.ai there and sign in again. Don't switch accounts inside one profile. |
| Chrome profile shows "extension NOT installed" | In that profile's window: Chrome Web Store ▸ Claude ▸ Add to Chrome (`claude-acct chrome add <name>` reopens the page). |
| `claude-acct: command not found` | `~/.local/bin` isn't on the login-shell PATH; the installer prints the line for `~/.zprofile` / `~/.bash_profile`. |
| Menu bar item missing | Behind the notch (too many menu bar icons). It starts next to the clock. ⌘-drag to move it; quit and reopen it from `~/Applications` if it's still hidden. |
| `⚠︎ HTTP 401` / "not signed in" in the menu | The account's refresh token expired (about monthly): `claude-acct add <name> <email>` again. |
| Limits look stale | Menu ▸ Refresh now (auto every 5 min). |

## Caveats

- The usage numbers come from the same **unofficial** endpoint Claude Code's `/usage` uses
  (`api.anthropic.com/api/oauth/usage`). It can change without notice. This tool isn't affiliated with Anthropic.
- Expired access tokens are refreshed the way Claude Code does it (rotating refresh token written back
  to the same keychain item), and only once they've expired, so an active Claude Code session refreshes first.
- Saved desktop logins are copies of the app's cookies, kept in `~/Library/Application Support/ClaudeUsage/desktop-profiles`
  (mode 700). The first switch also keeps a full backup in `.original-<time>/`, and each switch keeps the files it
  replaced in `.last-replaced/`.
