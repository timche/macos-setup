#!/bin/bash

# The first command a Mac has, and the only one that works before this repo is
# on it:
#
#   curl -fsSL https://raw.githubusercontent.com/timche/macos-setup/main/bootstrap.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/timche/macos-setup/main/bootstrap.sh | bash -s claude
#
# A fresh Mac has no git — it comes with the Xcode command line tools — and no
# package manager at all, so there is nothing here to clone with. Homebrew's own
# installer is what fixes both: it installs the tools through softwareupdate
# rather than the dialog nobody is in front of, and this repo needs Homebrew
# anyway. Then the git that arrived clones, and machine.sh takes over — followed
# by claude.sh, if that is what was asked for.
#
# The second entry point is the clone itself: once it is there, machine.sh and
# claude.sh are run directly and this script has nothing left to do.
#
# Unlike a VM there is no account to create, so this runs as the user the
# machine is for and sudo asks for their password along the way.
#
# Safe to re-run: an existing clone is pulled rather than recloned.

set -euo pipefail

repo_url="${MACOS_SETUP_REPO:-https://github.com/timche/macos-setup.git}"
homebrew_install=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh

# The overlay is opt-in, and the argument is the whole of the interface to it.
# Anything else is refused rather than ignored: a typo that quietly provisions a
# machine without the half you asked for is worse than one that stops.
overlay=false

if [ "$#" -gt 0 ]; then
  if [ "$#" -eq 1 ] && [ "$1" = claude ]; then
    overlay=true
  else
    echo "usage: bootstrap.sh [claude]" >&2
    echo "'claude' asks for the Claude Code overlay on top of the machine;" >&2
    echo "there is no other argument." >&2
    exit 1
  fi
fi

if [ "$(uname -s)" != Darwin ]; then
  echo "macos-setup is for a Mac; this is $(uname -s)." >&2
  exit 1
fi

# /opt/homebrew is the Apple Silicon prefix, and it is written into claude-dotfiles'
# PATH and into the agents launchd loads. An Intel Mac puts Homebrew in
# /usr/local and would come out of this half working with nothing saying why.
if [ "$(uname -m)" != arm64 ]; then
  echo "macos-setup is for an Apple Silicon Mac; this is $(uname -m), where" >&2
  echo "Homebrew lives in /usr/local rather than the /opt/homebrew everything" >&2
  echo "here and in claude-dotfiles expects." >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "bootstrap.sh runs as the account the machine is for, not as root —" >&2
  echo "Homebrew refuses to install as root and everything else here lands in" >&2
  echo "\$HOME. Log in as that account and start again; it needs to be an" >&2
  echo "administrator, since sudo is what the machine half runs on." >&2
  exit 1
fi

# Homebrew, and the command line tools with it

# NONINTERACTIVE because there is nobody to press RETURN, and because it is what
# keeps the installer on the softwareupdate path for the command line tools: its
# fallback is `xcode-select --install`, which puts up a dialog on a machine with
# no display. sudo still asks for a password, which is the one thing here that
# wants somebody at the keyboard.
if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  echo "Installing Homebrew, and the Xcode command line tools with it."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$homebrew_install")"
fi

# The installer puts nothing on PATH — that is what it prints instructions for —
# and the shell that would read them is claude-dotfiles' business rather than this
# script's. Skipped when brew is already reachable: a PATH that reaches it has an
# order somebody chose, and prepending the prefix again steps over it.
if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# The repo

# At the top of $HOME, beside claude-dotfiles and the docs: this is the machine
# rather than work done on it. Nothing installed from here points back into the
# clone, so it can be moved or deleted; it is kept because a Mac is pulled and
# re-run rather than reprovisioned from a URL. MACOS_SETUP_DIR moves it.
target="${MACOS_SETUP_DIR:-$HOME/macos-setup}"

if [ -d "$target/.git" ]; then
  git -C "$target" pull --ff-only
else
  git clone "$repo_url" "$target"
fi

# Hand over

# Under the documented curl install stdin is the pipe feeding this script, so
# every prompt in either half would be one nobody can answer. The terminal
# itself is the one to hand them, when there is one.
run() {
  if (exec </dev/tty) 2>/dev/null; then
    "$1" </dev/tty
  else
    "$1"
  fi
}

# A fumbled paste or a refused sudo is enough to make either half exit non-zero,
# and the closing message is worth more than the exit status is.
run_failed=0

run "$target/machine.sh" || run_failed=1

if [ "$overlay" = true ]; then
  run "$target/claude.sh" || run_failed=1
fi

cat <<EOF

Bootstrapped from $target. Pull it and re-run either half to pick up a change:

    git -C $target pull
    $target/machine.sh
EOF

if [ "$run_failed" -ne 0 ]; then
  echo
  echo "One of the halves did not finish — read back for which, and rerun it" >&2
  echo "from $target." >&2
fi

exit "$run_failed"
