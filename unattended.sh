#!/bin/bash

# What makes a Mac with nobody in front of it come back on its own: a restart
# after power loss, no sleeping, and a GUI login session to come back into.
#
# The session is the part that cannot be arranged from here. launchd puts a
# LaunchAgent in the gui/<uid> domain, which exists only while somebody is logged
# in at the console — so boswell, and the ssh-agent holding the signing key, are
# both running inside a login this machine has to perform on itself. Auto-login
# is the way it does, and setting it means writing an obfuscated password to
# /etc/kcpassword, which this script will not do: it checks instead and says so.
#
# Not fatal. A Mac that sleeps or comes up at the login window is still a Mac,
# and both of these are one switch away in System Settings.
#
# Safe to re-run: pmset takes the same values again, and the login check reads.

set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "unattended.sh is macOS only" >&2
  exit 1
fi

# Power

# One at a time rather than in a single call: what a Mac's hardware supports
# varies, an unsupported setting is simply absent from what pmset reports back,
# and a call that took three settings would be one warning about which of them
# did not land.
#
# displaysleep is deliberately not among them. There is no display, and a Mac
# blanking one it does not have costs nothing.
set_power() {
  local setting="$1" value="$2" current

  current="$(pmset -g custom | awk -v s="$setting" '$1 == s { print $2; exit }')"

  if [ "$current" = "$value" ]; then
    return 0
  fi

  if ! sudo pmset -a "$setting" "$value" >/dev/null 2>&1; then
    echo "could not set $setting to $value — this Mac may not support it" >&2
    return 0
  fi

  echo "pmset $setting is now $value"
}

# Power loss on a machine nobody can walk up to is otherwise a machine that is
# gone until somebody does.
set_power autorestart 1

# Sleep is the other way a Mac stops answering SSH without anything being wrong
# with it. disksleep as well as sleep, because a spun-down disk is what a woken
# machine waits on.
set_power sleep 0
set_power disksleep 0

# The login session

auto_login_user="$(
  defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true
)"
user="$(id -un)"

if [ "$auto_login_user" = "$user" ]; then
  echo "auto-login is on for $user"
else
  echo
  if [ -z "$auto_login_user" ]; then
    echo "warning: auto-login is off. After a restart this Mac sits at the login" >&2
    echo "window, where there is no gui/$(id -u) domain — so boswell and the" >&2
    echo "ssh-agent that holds the signing key are not running, and nothing says" >&2
    echo "so beyond commits failing to sign." >&2
  else
    echo "warning: auto-login logs in $auto_login_user rather than $user, whose" >&2
    echo "session is the one the agents are loaded into." >&2
  fi
  echo >&2
  echo "Turn it on in System Settings > Users & Groups > Automatic login, which" >&2
  echo "needs FileVault off. This script will not: it means writing the account" >&2
  echo "password to /etc/kcpassword, obfuscated rather than encrypted." >&2
fi
