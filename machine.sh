#!/bin/bash

# The whole of the machine: Homebrew and the packages, the Remote Login this Mac
# is reached through, the power settings that bring it back on its own, the
# tailnet, docker, and a hardened sshd. What it leaves is a Mac worth having with
# no account anywhere on it.
#
# An entry point, and the usual one: bootstrap.sh exists for a Mac that does not
# have this repo yet and calls this the moment it does. Running it again from the
# clone is how a change is picked up.
#
# Safe to re-run. Everything here checks the machine before touching it, which is
# the point on a Mac rather than a VM: this one was reachable over SSH and on the
# tailnet before the repo existed, and a second tailscale or a rewritten sshd
# would be a step backwards.

set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "macos-setup is for a Mac; this is $(uname -s)." >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "machine.sh runs as the account the machine is for, not as root —" >&2
  echo "Homebrew refuses root outright and everything else here lands in" >&2
  echo "\$HOME. It sudos for the parts that need it." >&2
  exit 1
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Asked for once, up front, rather than partway through a long brew run. The
# timestamp lasts five minutes, so a slow download can still cost a second
# password — there is no root account here to lend this one a passwordless sudo
# the way provision.sh does on a VM.
if ! sudo -v; then
  echo "machine.sh needs sudo — the account has to be an administrator." >&2
  exit 1
fi

"$repo/bootstrap-system.sh"
"$repo/remote-login.sh"
"$repo/unattended.sh"
"$repo/tailscale.sh"
"$repo/docker.sh"

# Last of the steps that decide how this Mac is reached, because it is the one
# that turns password logins off. It skips itself when there is no authorized_keys
# yet, rather than locking you out of a machine that is nowhere near you.
"$repo/harden-ssh.sh"

# After everything else, because it is an 11GB download and an Apple ID typed in
# at the time: nothing in the run should wait behind that. A terminal is the whole
# of the condition — with none there is nobody to type it, and the footer below
# says the step is still to do.
xcode_left=false

if [ -t 0 ]; then
  "$repo/xcode.sh" || xcode_left=true
else
  xcode_left=true
  echo
  echo "Skipped xcode.sh — no terminal to type an Apple ID at."
fi

echo
echo "Done. What is left:"
echo

# Presence rather than `tailscale status`, which the app's CLI does not answer
# from a PATH it was never added to.
if [ ! -d /Applications/Tailscale.app ] && ! command -v tailscale >/dev/null 2>&1; then
  echo "  - $repo/tailscale.sh — there is no tailscale on this Mac."
fi

if [ "$xcode_left" = true ]; then
  echo "  - $repo/xcode.sh — Xcode itself, which signs meru's builds. It wants a"
  echo "    terminal, an Apple ID and an hour."
fi

# Reported here as well as by docker.sh, because the VM's first boot is the
# longest thing in a run and its failure scrolls a long way up. The prefix is
# spelled out because this shell can predate Homebrew being on any PATH —
# bootstrap-system.sh put it on its own, not on this one.
if ! /opt/homebrew/bin/colima status >/dev/null 2>&1; then
  echo "  - $repo/docker.sh — the colima VM is not running."
fi

# tailscaled does not answer SSH on a Mac, so unlike a Linux box there is no
# second way in that the tailnet provides by itself: what governs every
# connection is the drop-in above, and what decides who reaches it is the tailnet
# policy.
cat <<'EOF'
  - An ssh rule for this machine in the tailscale admin console, if it is meant
    to be reachable from the tailnet at all.
EOF
