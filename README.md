# claude-accounts

Use several Claude accounts on one Mac — work, personal, a team org — without the sign-in e-mail every
time you switch, and keep an eye on every account's usage limits from the menu bar.

- **`claude-acct`**: one Claude Code login per account, each signed in once. Run `claude-acct work` or
  `claude-acct personal`, or switch a shell with `eval "$(claude-acct env work)"`.
- **Batch sign-in**: list your accounts once, and `claude-acct setup` walks through them, opening each
  sign-in in a private browser window so the browser can't sign you in as the wrong account.
- **Desktop app switcher**: switch the Claude desktop app between saved logins from the menu bar (it quits and
  reopens Claude).
- **Claude Usage menu bar app**: each account's 5-hour and weekly limits, with reset times.

It is also a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills): with it installed,
Claude knows how to set up, switch and troubleshoot your accounts.

## Install

Requires macOS 14+, [Claude Code](https://docs.claude.com/en/docs/claude-code), and the Xcode command line
tools (`xcode-select --install`) to build the menu bar app.

```bash
git clone https://github.com/jzennamo/claude-accounts.git ~/claude-accounts
~/claude-accounts/install.sh
```

The installer builds the app into `~/Applications`, links `claude-acct` into `~/.local/bin`, and links the
skill into `~/.claude/skills`. If `~/.local/bin` isn't on your PATH, it prints the line to add.
Use `--no-app` for just the command, and `--uninstall` to remove everything (your logins stay).

## Sign in all your accounts

```bash
claude-acct setup --desktop
```

The first time, it asks for your accounts (name + e-mail) and saves them to
`~/.config/claude-accounts/accounts` (format: `accounts.example`). Then, for each account:

1. Press return. A **private** browser window opens on the Claude sign-in page with the e-mail filled in.
2. Sign in. If you get an e-mail link, right-click it ▸ **Copy Link** and paste it into the private
   window. Clicking it would open your normal browser, which may already be signed in as someone else.
3. It checks you signed in as the right account. A wrong or duplicate account is removed again, and you're
   offered a retry.

With `--desktop` it then does the same for the desktop app. For each account, Claude quits and reopens signed
out, and you sign in once. Run that from **Terminal**, not from inside the Claude app.

Re-running `setup` only signs in what's missing. Logins last about a month; after that, `setup` re-does only
the expired ones.

## Everyday use

| | |
|---|---|
| Run Claude Code as an account | `claude-acct personal` (args pass through: `claude-acct work -p "…"`) |
| See accounts | `claude-acct list`, `claude-acct desktop list` |
| Switch the desktop app | menu bar ▸ Desktop app ▸ *account* (or `claude-acct desktop switch personal`) |
| Usage limits | the menu bar number is each account's highest limit; open the menu for details, or `claude-usage --dump` |
| Add one more account | `claude-acct add team me@team.org`, then `claude-acct desktop setup team` |

## How it works

- **Claude Code** keeps its login in the macOS keychain, under a name derived from its config folder. Each
  account gets its own folder (`~/.claude-accounts/<name>`), so each has its own login, history and projects.
  Your `CLAUDE.md`, settings and skills are linked in, so they are shared.
- **Desktop app**: its login is its claude.ai cookies + web storage + three keys in its `config.json`. A switch
  saves those for the current account and restores the other account's. Settings, Code sessions and worktrees
  aren't touched.
- **Usage**: the menu app reads each account's token from the keychain and asks the same endpoint Claude Code's
  `/usage` uses. It refreshes an expired token exactly as Claude Code would.

## Caveats

- Not affiliated with Anthropic. The usage endpoint is **unofficial** and may change.
- Saved desktop logins are copies of the app's cookies, in `~/Library/Application Support/ClaudeUsage`
  (readable only by you). Treat that folder like a password store. The first switch keeps a full backup of
  the original state there.
- Switching the desktop app quits it, which stops anything running in it.
- macOS only.

## License

MIT
