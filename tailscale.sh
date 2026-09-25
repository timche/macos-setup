#!/bin/bash

# Put tailscale on the Mac, which is the network this machine is reached over.
# A step of its own because it is the one part of the machine that already
# existed before this repo did: whoever set this Mac up reached it over the
# tailnet to run any of this, so the first thing to do is look, and the best
# outcome is to change nothing.
#
# The standalone app rather than the open-source `tailscale` formula. The formula
# is tailscaled in userspace networking, which accepts connections but does not
# route the machine's own traffic; the app installs a system network extension
# and behaves like tailscale does everywhere else. The cost is a one-time
# approval in System Settings that only somebody looking at the screen can give —
# which is why this script installs and stops there rather than pretending it can
# bring a fresh Mac up on the tailnet unattended.
#
# Nothing here advertises tailscale ssh. tailscaled does not answer SSH on a Mac,
# so the way in over the tailnet is the Remote Login sshd that remote-login.sh
# turns on, and harden-ssh.sh's drop-in governs it.
#
# Not fatal. By the time this runs the rest of the machine is built, and a tailnet
# can be sorted out afterwards.
#
# Safe to re-run: a Mac that already has tailscale, in either variant, is left
# alone.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

app=/Applications/Tailscale.app

# The app's own CLI, which is where the cask leaves it. Not symlinked onto PATH:
# the binary resolves its bundle from the path it was invoked through and refuses
# to run through a link, so the app's "Install CLI" is the only thing that should
# put it there.
app_cli="$app/Contents/MacOS/Tailscale"

if [ -d "$app" ]; then
  # Presence is as far as this looks. Asking the app's binary for `status` is what
  # would say whether it is on the tailnet, and on a Mac where the system
  # extension has not been allowed yet that call waits rather than answering —
  # which turned a re-run into a machine.sh that never finished.
  cat <<EOF
tailscale is already installed and left alone. If it is not on the tailnet, open
the app on the screen or sign in with:
  $app_cli up
EOF

  exit 0
fi

# The formula, if somebody chose it deliberately. Installing the app over the top
# would leave two tailscaled with one tailnet between them.
if command -v tailscale >/dev/null 2>&1; then
  echo "tailscale is already installed, from the open-source package rather" \
       "than the app — left alone"
  exit 0
fi

if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Renamed from `tailscale`, which now aliases to it and is not promised to keep
# doing so; the formula of the same name is the other variant entirely.
if ! brew install --cask tailscale-app; then
  echo "could not install tailscale — rerun $repo/tailscale.sh to try again" >&2
  exit 0
fi

cat <<EOF

tailscale is installed. Two things only somebody at the screen can do, which is
Screen Sharing on a Mac with no display:

  - Allow the system extension in System Settings > General > Login Items &
    Extensions > Network Extensions. Nothing routes until it is allowed.
  - Sign in to the tailnet, from the app or with: $app_cli up
EOF
