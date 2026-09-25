#!/bin/bash

# Assertions against a Mac that machine.sh has just finished with — the generic
# half only, with assert-claude.sh covering the overlay. Runs on the machine
# itself, which is a CI runner: there is no macOS container to put any of this in.
#
# To add a case, add a check line: a description and a shell snippet that exits
# non-zero when the expectation is not met.

set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"
export root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

check() {
  local description="$1" snippet="$2"

  if bash -c "$snippet" >/dev/null 2>&1; then
    echo "  ok    $description"
  else
    echo "  FAIL  $description"
    failures=$((failures + 1))
  fi
}

# This repo is public and holds no personal configuration at all — the shell, the
# runtimes and ~/.claude all come from the private one. A stray dot directory here
# would be a leak.
check "no personal config in this repo" \
  '! find "$root" \( -name .claude -o -name home \) -not -path "*/.git/*" | grep -q .'

# Nothing may be written for one account: the Mac's is timche and a runner's is
# runner, and a path hardcoded for either is a script that silently does nothing
# on the other. The dscl and launchctl reads that build a path from a variable are
# what this has to leave alone, which is why the pattern needs a literal name.
check "no hardcoded home directory in the scripts" \
  '! grep -rhoE --include="*.sh" --include="*.plist" "/Users/[A-Za-z0-9_.-]+" "$root" |
     grep -q .'

# Homebrew and its packages, which is all the machine half installs.
check "brew is the Apple Silicon prefix" '[ -x /opt/homebrew/bin/brew ]'
check "gh installed"   'command -v gh'
check "jq installed"   'command -v jq'
check "btop installed" 'command -v btop'
check "op installed"   'command -v op'
check "op is where launchd will look for it" '[ -x /opt/homebrew/bin/op ]'
check "git came with the command line tools" \
  '[ -x /Library/Developer/CommandLineTools/usr/bin/git ] || xcode-select -p'

check "tailscale is installed" \
  '[ -d /Applications/Tailscale.app ] || command -v tailscale'

# docker, which on a Mac is a Linux VM and a CLI pointed into it.
check "colima installed"         'command -v colima'
check "docker installed"         'command -v docker'
check "docker-compose installed" 'brew list --formula -1 | grep -qx docker-compose'
check "docker-buildx installed"  'brew list --formula -1 | grep -qx docker-buildx'

# Homebrew puts the plugins in its own prefix rather than the ~/.docker/cli-plugins
# the CLI searches by itself, so a docker that cannot find them has compose and
# buildx as nothing at all. Exactly once, because the merge runs on every provision.
plugin_dirs() {
  jq -r '.cliPluginsExtraDirs // [] | .[]' "$HOME/.docker/config.json"
}
export -f plugin_dirs

check "docker's config names Homebrew's plugin directory exactly once" \
  '[ "$(plugin_dirs | grep -cxF /opt/homebrew/lib/docker/cli-plugins)" = 1 ]'
check "docker compose resolves as a plugin" 'docker compose version'
check "docker buildx resolves as a plugin"  'docker buildx version'

# The VM's shape, which is the machine's rather than a number in the script. The
# arithmetic is spelled out again instead of sourced, because what this asserts is
# that docker.sh read the hardware at all.
colima_value() {
  sed -n "s/^$1: *//p" "$HOME/.colima/default/colima.yaml" | head -1
}
export -f colima_value

want_cpu=$(($(sysctl -n hw.ncpu) - 2))
[ "$want_cpu" -lt 2 ] && want_cpu=2

want_memory=$(($(sysctl -n hw.memsize) / 1073741824 / 2))
[ "$want_memory" -lt 2 ] && want_memory=2

check "colima has a profile config" '[ -f "$HOME/.colima/default/colima.yaml" ]'
check "colima's VM is every core but two" \
  "[ \"\$(colima_value cpu)\" = $want_cpu ]"
check "colima's VM is half the memory" \
  "[ \"\$(colima_value memory)\" = $want_memory ]"
check "colima's VM has a 100GiB disk" '[ "$(colima_value disk)" = 100 ]'
check "colima's VM is vz with rosetta" \
  '[ "$(colima_value vmType)" = vz ] && [ "$(colima_value rosetta)" = true ]'

# The VM itself, which a runner cannot have: GitHub's macOS machines are VMs
# already and Virtualization.framework inside one refuses outright with
# "Virtualization is not available on this hardware", with or without rosetta. Said
# out loud, because a suite that quietly asserted nothing here would read the same
# on a Mac where docker is broken.
if colima status >/dev/null 2>&1; then
  check "docker's context is colima" '[ "$(docker context show)" = colima ]'
  check "a container runs" 'docker run --rm hello-world'
  check "a two-service compose file comes up and goes down" \
    'docker compose -f "$root/test/compose.yaml" up -d &&
     running="$(docker compose -f "$root/test/compose.yaml" ps -q | grep -c .)";
     docker compose -f "$root/test/compose.yaml" down &&
     [ "$running" = 2 ]'
else
  echo "  --    the colima VM is not running, so docker itself was not checked"
fi

# Nothing in the generic half has an opinion about the shell or the dotfiles: both
# are claude-dotfiles', which installs them as symlinks out of its own checkout.
# A runner may well arrive with rc files of its own, so the link is the assertion
# rather than the file.
check "no rc file was linked" '[ ! -L "$HOME/.zshrc" ] && [ ! -L "$HOME/.gitconfig" ]'

# What a Mac's hardware supports varies, and an unsupported setting is absent from
# what pmset reports rather than wrong — a virtualised runner has no power supply
# to come back from. Absent is reported rather than asserted, so this says which
# of them the machine it ran on could actually be told.
power_setting() {
  pmset -g custom | awk -v s="$1" '$1 == s { print $2; exit }'
}
export -f power_setting

for pair in autorestart:1 sleep:0 disksleep:0; do
  setting="${pair%%:*}"
  want="${pair##*:}"

  if [ -z "$(power_setting "$setting")" ]; then
    echo "  --    pmset does not report $setting on this Mac"
  else
    check "pmset $setting is $want" "[ \"\$(power_setting $setting)\" = $want ]"
  fi
done

# Reading the system domain needs root, and a Mac being provisioned by hand should
# not have this script sitting on a password prompt.
if sudo -n true 2>/dev/null; then
  check "Remote Login is on" \
    'sudo -n launchctl print system/com.openssh.sshd'
else
  echo "  --    sudo wants a password, so Remote Login was not checked"
fi

# harden-ssh.sh holds the drop-in back until there is a key to log in with, so
# which half of this is asserted depends on whether the caller has seeded one yet.
# Both halves matter: the refusal is what keeps a Mac nobody can walk up to
# reachable. The test is the one harden-ssh.sh gates on, not -s, or a file of
# unusable lines sends this down the wrong half.
if ssh-keygen -l -f "$HOME/.ssh/authorized_keys" >/dev/null 2>&1; then
  check "sshd drop-in names this user" \
    'grep -qx "AllowUsers $(id -un)" /etc/ssh/sshd_config.d/10-hardening.conf'
  check "sshd drop-in kept no placeholder" \
    '! grep -q __USER__ /etc/ssh/sshd_config.d/10-hardening.conf'
  check "sshd drop-in disables passwords" \
    'grep -qx "PasswordAuthentication no" /etc/ssh/sshd_config.d/10-hardening.conf'
  check "sshd drop-in belongs to root" \
    '[ "$(stat -f "%Su %Lp" /etc/ssh/sshd_config.d/10-hardening.conf)" = "root 644" ]'
  # macOS reads the config per connection rather than holding it in a running
  # daemon, so a drop-in it cannot parse breaks every login rather than waiting
  # for a restart.
  check "sshd accepts the drop-in" 'sudo -n /usr/sbin/sshd -t'
else
  check "no drop-in until there is a key to log in with" \
    '[ ! -f /etc/ssh/sshd_config.d/10-hardening.conf ]'
  check "harden-ssh.sh refuses rather than failing the run" '"$root/harden-ssh.sh"'
fi

# macOS has shipped the Include since Monterey, and without it the drop-in above
# is a file nothing reads.
check "sshd_config includes the drop-in directory" \
  'grep -qE "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/" /etc/ssh/sshd_config'

if [ "$failures" -gt 0 ]; then
  echo "  $failures check(s) failed"
  exit 1
fi
