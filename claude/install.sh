#!/bin/bash

# Fetch the private half and let it take over. Everything personal — the shell,
# the prompt, the runtimes, the Claude Code configuration — lives in
# claude-dotfiles, so all this script does is get it onto the machine and run its
# installer.
#
# That needs an authenticated gh, which a fresh Mac does not have when claude.sh
# first reaches this. So it says what is missing and returns, and login.sh runs it
# again once there is a token. This is also the script to rerun by hand after one
# expires.
#
# Safe to re-run: an existing clone is pulled rather than recloned.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated — run $repo/login.sh, which logs in and comes" >&2
  echo "back here for the dotfiles" >&2
  exit 0
fi

# Hidden, because it is machinery rather than work: $HOME holds what is worked
# on, and this is what makes the account itself. CLAUDE_DOTFILES_DIR moves it.
dotfiles="${CLAUDE_DOTFILES_DIR:-$HOME/.claude-dotfiles}"

# gh clones a private repo by injecting the token itself, but the git that pulls
# it afterwards has no idea where to find one, and a clone that cannot be updated
# is worse than no clone: the installer below would run from it and fail on
# whatever the old version expected. So the pull is handed gh's helper for that
# one command. Not `gh auth setup-git`: it writes gh's absolute path into
# ~/.gitconfig, which by a rerun is a link into claude-dotfiles, shared with a VM
# that has no /opt/homebrew — git there would stop finding credentials.
gh_git() {
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
}

# Nobody but the owner can clone it, so a failure here is a message rather than
# the end of the run: the machine machine.sh built still works.
if [ -d "$dotfiles/.git" ]; then
  gh_git -C "$dotfiles" pull --ff-only ||
    echo "could not update $dotfiles — the installer below runs from it as it" \
         "is, which is a version behind whatever it should be" >&2
else
  gh repo clone "${CLAUDE_DOTFILES_REPO:-timche/claude-dotfiles}" "$dotfiles" ||
    echo "could not clone the dotfiles repo — the shell stays as macOS left it" >&2
fi

if [ -x "$dotfiles/install.sh" ]; then
  "$dotfiles/install.sh"
fi

# signing-key.sh is what fetches the key out of 1Password; registering it needs
# the gh that only exists by this point.
"$repo/register-signing-key.sh"
