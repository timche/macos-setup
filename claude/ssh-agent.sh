#!/bin/bash

# Install and load the LaunchAgent that keeps the signing key in an ssh-agent of
# its own. What it runs is launchd/agent.sh, copied out of the repo rather than
# run from it, so that the checkout stays something that can be moved or deleted.
#
# Rendered rather than linked: launchd expands neither ~ nor $HOME in a plist, and
# the PATH it hands a job reaches neither op nor anything else Homebrew installed.
#
# The agent lives in the gui/<uid> domain, which exists only while the account is
# logged in at the console — so this is the other half of the auto-login
# unattended.sh checks for, and an SSH session against a Mac sitting at its login
# window cannot load it at all.
#
# Safe to re-run: the plist and the script are compared before anything is
# replaced, and launchd is only disturbed when one of them changed.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$repo/.." && pwd)"

label=io.github.timche.ssh-agent
plist="$HOME/Library/LaunchAgents/$label.plist"
agent="$HOME/.ssh/agent.sh"
log="$HOME/Library/Logs/ssh-agent.log"
socket="$HOME/.ssh/agent.sock"
uid="$(id -u)"

# Carried into the plist, because the agent has no environment but the one it is
# given and these are the two things about it worth overriding.
item="${SIGNING_KEY_OP_ITEM:-op://Claude/SSH Key}"
token_file="${OP_SERVICE_ACCOUNT_TOKEN_FILE:-$HOME/.config/op/service-account-token}"

if ! command -v op >/dev/null 2>&1; then
  echo "op is not installed, so the agent was not installed — it is brew's," >&2
  echo "and brew is machine.sh's." >&2
  exit 0
fi

# Wherever Homebrew's prefix is, plus the directories everything else in the
# wrapper comes from. sudo is not among them: nothing the agent does needs it.
agent_path="$(cd "$(dirname "$(command -v op)")" && pwd):/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
mkdir -p "$HOME/Library/LaunchAgents"

# launchd will not start a job whose log directory is missing.
mkdir -p "$HOME/Library/Logs"

agent_changed=false
if ! cmp -s "$root/launchd/agent.sh" "$agent"; then
  install -m 700 "$root/launchd/agent.sh" "$agent"
  agent_changed=true
fi

staged="$(mktemp)"
trap 'rm -f "$staged"' EXIT

# | rather than / as the delimiter: every value substituted here is a path or a
# secret reference, and all of them have slashes in.
sed -e "s|__AGENT__|$agent|" \
    -e "s|__LOG__|$log|" \
    -e "s|__PATH__|$agent_path|" \
    -e "s|__SOCKET__|$socket|" \
    -e "s|__TOKEN_FILE__|$token_file|" \
    -e "s|__OP_ITEM__|$item|" \
    "$root/launchd/$label.plist" >"$staged"

plist_changed=false
if ! cmp -s "$staged" "$plist"; then
  install -m 644 "$staged" "$plist"
  plist_changed=true
fi

loaded=false
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
  loaded=true
fi

# launchd holds the plist it read at bootstrap, and kickstart restarts the process
# from that copy — so a changed plist is a bootout and a fresh bootstrap or it is
# nothing at all.
if [ "$loaded" = true ] && [ "$plist_changed" = true ]; then
  launchctl bootout "gui/$uid/$label" || true
  loaded=false
fi

if [ "$loaded" = false ]; then
  if launchctl bootstrap "gui/$uid" "$plist"; then
    echo "loaded $label"
  else
    echo "could not load $label — the gui/$uid domain belongs to a console" >&2
    echo "login, which a Mac sitting at its login window does not have. Log in" >&2
    echo "there, or turn auto-login on, and run this again:" >&2
    echo "  $repo/ssh-agent.sh" >&2
    exit 0
  fi
elif [ "$agent_changed" = true ]; then
  launchctl kickstart -k "gui/$uid/$label"
  echo "restarted $label, which is what re-reads the key"
else
  echo "$label is already loaded"
fi

# The key comes out of 1Password over the network, so there is nothing to see for
# a moment after the job starts.
waited=0
while [ "$waited" -lt 30 ]; do
  if SSH_AUTH_SOCK="$socket" ssh-add -l >/dev/null 2>&1; then
    echo "the agent holds $(SSH_AUTH_SOCK="$socket" ssh-add -l | wc -l | tr -d ' ') key(s)"
    exit 0
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "the agent is loaded but holding no key yet — it keeps trying, and the" >&2
echo "reason is in $log" >&2
