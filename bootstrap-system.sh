#!/bin/bash

# Homebrew, the Xcode command line tools it brings with it, and the packages.
# Needs sudo the first time only — Homebrew's installer is what wants it, and
# everything after that lands in a prefix the account owns.
#
# Every package here is one something later cannot start without: claude.sh
# clones a private repo with gh, patches a config with jq and reads the signing
# key out of 1Password with op, and claude-dotfiles' install.sh stops with a
# message if it cannot find brew at all. btop is the one that is only for
# whoever logs in to look at the machine.
#
# Safe to re-run: an existing Homebrew is left alone and packages already
# installed are skipped rather than upgraded, so a re-run is not a way to move
# versions.

set -euo pipefail

homebrew_install=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh

formulae=(btop gh jq)

# op, and the cask rather than a formula because 1Password ships the CLI itself.
# It is a zip with a binary in it these days, so nothing here needs sudo for it.
casks=(1password-cli)

# NONINTERACTIVE because there is nobody to press RETURN, and because it is what
# keeps the installer on the softwareupdate path for the command line tools: the
# fallback is `xcode-select --install`, which puts a dialog on a display this Mac
# does not have. The installer checks for the tools' own git rather than
# xcode-select, so a Mac with Xcode proper is left alone too.
if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$homebrew_install")"
fi

# The installer only prints the line that would do this, and the shell that reads
# that line is claude-dotfiles'. Skipped when brew is already reachable: a PATH that
# reaches it has an order somebody chose, and prepending the prefix again steps over
# it.
if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Listed once and compared, rather than leaning on `brew install` being a no-op:
# it is, but it prints a warning per package that reads like something went
# wrong.
installed_formulae="$(brew list --formula -1)"
installed_casks="$(brew list --cask -1)"

for formula in "${formulae[@]}"; do
  if printf '%s\n' "$installed_formulae" | grep -qxF "$formula"; then
    continue
  fi
  brew install "$formula"
done

for cask in "${casks[@]}"; do
  if printf '%s\n' "$installed_casks" | grep -qxF "$cask"; then
    continue
  fi
  brew install --cask "$cask"
done
