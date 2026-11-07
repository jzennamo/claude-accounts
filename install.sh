#!/usr/bin/env bash
# Install claude-accounts: the claude-acct command, the Claude Usage menu bar app, and the Claude skill.
#   ./install.sh              install or update
#   ./install.sh --no-app     command + skill only (no menu bar app, no Xcode tools needed)
#   ./install.sh --uninstall  remove the app, command and skill link (your accounts and saved logins stay)
set -euo pipefail
R=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"; APPS="$HOME/Applications"; SK="$HOME/.claude/skills/claude-accounts"
die() { echo "error: $*" >&2; exit 1; }
[ "$(uname)" = Darwin ] || die "macOS only"
mode=${1:-install}

if [ "$mode" = --uninstall ]; then
  pkill -x ClaudeUsage 2>/dev/null || true
  rm -rf "$APPS/ClaudeUsage.app"
  for f in claude-acct claude-usage; do [ -L "$BIN/$f" ] && rm "$BIN/$f"; done
  [ -L "$SK" ] && rm "$SK"
  echo "Removed. Left in place (delete by hand if you want): ~/.claude-accounts (Claude Code logins),"
  echo "~/Library/Application Support/ClaudeUsage (saved desktop logins), ~/.config/claude-accounts (account list)."
  exit 0
fi

command -v python3 >/dev/null || die "python3 not found (install the Xcode command line tools: xcode-select --install)"
command -v claude >/dev/null || echo "note: Claude Code ('claude') isn't on PATH; install it first for the Claude Code accounts."
mkdir -p "$BIN"
chmod +x "$R/bin/"* "$R/app/build.sh"
ln -sf "$R/bin/claude-acct" "$BIN/claude-acct"

if [ "$mode" != --no-app ]; then
  xcrun --find swiftc >/dev/null 2>&1 || die "Swift compiler not found: run 'xcode-select --install' (or use --no-app)"
  "$R/app/build.sh"
  mkdir -p "$APPS"
  pkill -x ClaudeUsage 2>/dev/null || true; sleep 1
  rm -rf "$APPS/ClaudeUsage.app"; cp -R "$R/app/build/ClaudeUsage.app" "$APPS/"
  ln -sf "$APPS/ClaudeUsage.app/Contents/MacOS/ClaudeUsage" "$BIN/claude-usage"
  open "$APPS/ClaudeUsage.app"
  echo "✓ Claude Usage is in the menu bar (gauge icon; ⌘-drag it if you want it elsewhere)"
fi

if [ -d "$HOME/.claude" ]; then
  mkdir -p "$HOME/.claude/skills"
  if [ -L "$SK" ] || [ ! -e "$SK" ]; then
    [ "$(readlink -f "$SK" 2>/dev/null)" = "$R" ] || ln -sfn "$R" "$SK"
    echo "✓ skill linked: $SK"
  else
    echo "note: $SK exists and isn't a link; left it alone."
  fi
fi

echo "✓ claude-acct installed in $BIN"
if ! bash -lc 'command -v claude-acct' >/dev/null 2>&1 && ! zsh -lc 'command -v claude-acct' >/dev/null 2>&1; then
  echo
  echo "$BIN isn't on your PATH yet. Add it (zsh is the macOS default shell):"
  echo "  zsh:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile"
  echo "  bash: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bash_profile"
  echo "then open a new Terminal window."
fi
echo
echo "Next: sign in all your accounts in one go —"
echo "  claude-acct setup --desktop      (or menu bar ▸ Sign in all my accounts…)"
