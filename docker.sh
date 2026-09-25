#!/bin/bash

# Docker on a Mac, which means a Linux VM and a CLI that talks into it: colima
# runs the VM under Virtualization.framework with a docker daemon inside it, and
# the docker command on this side reaches that daemon over a socket colima
# publishes. Every part of it is Homebrew's.
#
# colima rather than Docker Desktop. Desktop is an app — an installer that
# expects somebody at the screen, a menu bar item to log in to, and a licence
# whoever owns the Mac would have to buy — where colima is a CLI that starts a
# VM and gets out of the way.
#
# The VM is started by `brew services`, which means a LaunchAgent, which lives in
# the gui/<uid> domain — so docker here is only running once the Mac has logged
# itself in. That is the auto-login unattended.sh checks for and will not turn on,
# and it is the same thing the agent holding the signing key depends on.
#
# Not fatal. Every step says what it could not do, and a Mac with no VM running
# is still the machine the rest of this repo built.
#
# Safe to re-run: packages are compared before they are installed, the docker
# config is merged rather than rewritten, and a VM that already exists is reported
# on rather than resized — colima can grow a disk but never shrink one, and
# recreating a VM loses every image and volume in it.

set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "docker.sh is macOS only" >&2
  exit 1
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# The packages

# docker is the CLI on its own — the daemon is the one inside the VM — and
# Homebrew packages the two plugins separately from the CLI that loads them.
formulae=(colima docker docker-compose docker-buildx)

# Listed once and compared rather than leaning on `brew install` being a no-op:
# it is, but it prints a warning per package that reads like something went
# wrong. The same reason bootstrap-system.sh does it this way; the packages are
# here rather than there because this script is the only thing that wants them
# and, like tailscale.sh, it is the one that knows what to check first.
installed="$(brew list --formula -1)"

for formula in "${formulae[@]}"; do
  if printf '%s\n' "$installed" | grep -qxF "$formula"; then
    continue
  fi

  if ! brew install "$formula"; then
    echo "could not install $formula — rerun $repo/docker.sh to try again" >&2
    exit 0
  fi
done

# The plugins

# `docker compose` and `docker buildx` are subcommands only where the CLI can
# find the plugin binaries, and Homebrew installs them in its own prefix rather
# than the ~/.docker/cli-plugins the CLI searches by itself. Both formulae print
# the same caveat, and this is it.
plugin_dir=/opt/homebrew/lib/docker/cli-plugins
docker_config="$HOME/.docker/config.json"

mkdir -p "$(dirname "$docker_config")"

if [ ! -f "$docker_config" ]; then
  echo '{}' >"$docker_config"
fi

# Merged rather than written: this is also the file docker keeps the current
# context in — colima sets one — and whatever credential helper a registry login
# left behind.
if ! jq -e . "$docker_config" >/dev/null 2>&1; then
  echo "warning: $docker_config is not JSON jq can read, so it was left alone." >&2
  echo "Until it lists $plugin_dir in cliPluginsExtraDirs," >&2
  echo "docker compose and docker buildx are not subcommands." >&2
else
  # Appended when it is missing rather than added and deduplicated, because the
  # order of those directories is the order the CLI searches them in.
  merged="$(
    jq --arg dir "$plugin_dir" '
      .cliPluginsExtraDirs = (
        (.cliPluginsExtraDirs // []) | if index($dir) then . else . + [$dir] end
      )
    ' "$docker_config"
  )"

  if [ "$merged" != "$(cat "$docker_config")" ]; then
    tmp="$(mktemp "$docker_config.XXXXXX")"
    printf '%s\n' "$merged" >"$tmp"
    mv "$tmp" "$docker_config"
    echo "docker's config now names Homebrew's plugin directory"
  fi
fi

# The VM's shape

# All the cores but two, so that macOS and whatever is watching the machine keep
# somewhere to run, and half the memory. Read from the hardware rather than
# written down: this repo is aimed at one Mac, but nothing in it should have to be
# edited to suit the next one.
cores="$(sysctl -n hw.ncpu)"
cpu=$((cores - 2))
if [ "$cpu" -lt 2 ]; then
  cpu=2
fi

memory=$(($(sysctl -n hw.memsize) / 1073741824 / 2))
if [ "$memory" -lt 2 ]; then
  memory=2
fi

# colima's own default, and a ceiling rather than a reservation: the image is
# sparse, so it costs what the images and volumes in it actually take. Worth
# having generous, because growing a disk needs a restart and shrinking one is not
# possible at all.
disk=100

config="$HOME/.colima/default/colima.yaml"

# vz is Virtualization.framework, macOS's own hypervisor: on Apple Silicon it is
# faster than the qemu colima otherwise defaults to, and it is what virtiofs and
# Rosetta both need. Rosetta is what runs an amd64 image at close to native speed,
# which matters because plenty of what a registry holds is amd64 only.
#
# Written to the profile config rather than passed as flags to a start, because
# from here on the thing that starts this VM is the LaunchAgent below, and it runs
# `colima start` with no arguments at all. colima rewrites this file in its own
# fully commented form on the first start and keeps these values.
#
# runtime is in it because a config with no runtime is one colima reads as absent:
# it would fall back to its defaults, which are two cores and two GiB.
if [ ! -f "$config" ]; then
  mkdir -p "$(dirname "$config")"

  cat >"$config" <<EOF
cpu: $cpu
memory: $memory
disk: $disk
vmType: vz
rosetta: true
mountType: virtiofs
runtime: docker
EOF

  echo "colima will build a VM of $cpu CPUs, ${memory}GiB of memory and ${disk}GiB of disk"
else
  differences=""

  for pair in "cpu $cpu" "memory $memory" "disk $disk" "vmType vz" "rosetta true"; do
    key="${pair%% *}"
    want="${pair##* }"
    have="$(sed -n "s/^$key: *//p" "$config" | head -1)"

    if [ "$have" != "$want" ]; then
      differences="$differences
  $key is ${have:-unset}, where this Mac works out to $want"
    fi
  done

  if [ -z "$differences" ]; then
    echo "colima's VM is $cpu CPUs, ${memory}GiB of memory and ${disk}GiB of disk"
  else
    echo
    echo "colima's config asks for a different VM than this Mac works out to:$differences"

    cat <<EOF

Left as it is, since somebody chose it and rebuilding a VM is not free. To move
to the numbers above, edit them in and restart:

  colima stop && colima start --edit

cpu and memory take effect at that start and a disk can grow, but vmType and
mountType are fixed when the VM is created — changing either means deleting it,
which loses every image and volume in it:

  colima delete && $repo/docker.sh
EOF
  fi
fi

# Start at login

log=/opt/homebrew/var/log/colima.log
started=false

# brew's own list rather than looking for the plist, whose label has changed name
# between Homebrew versions.
case "$(brew services list | awk '$1 == "colima" { print $2 }')" in
started | scheduled)
  echo "colima's LaunchAgent is already loaded"
  ;;
error)
  # Loaded, and its last start failed — which the report at the end of this
  # script is about to explain. Asking brew to start it again only prints brew's
  # own refusal, since launchd has it either way.
  echo "colima's LaunchAgent is loaded, and its last start did not take"
  ;;
*)
  log_mark=0
  if [ -f "$log" ]; then
    log_mark="$(wc -l <"$log" | tr -d ' ')"
  fi

  if brew services start colima; then
    started=true
  else
    echo "warning: brew would not start colima. 'brew services list' says where" >&2
    echo "it is, and 'brew services restart colima' is the usual answer." >&2
  fi
  ;;
esac

# Waited on only when this run is what asked for the start. The first boot takes
# about a minute, longer while it is still pulling the VM image, and the log is
# what says the attempt is over — without reading it a Mac where the VM cannot
# start at all would sit here for the whole timeout before saying so.
if [ "$started" = true ]; then
  waited=0

  while [ "$waited" -lt 90 ]; do
    if colima status >/dev/null 2>&1; then
      break
    fi

    if tail -n "+$((log_mark + 1))" "$log" 2>/dev/null | grep -q 'level=fatal'; then
      break
    fi

    sleep 3
    waited=$((waited + 3))
  done
fi

if colima status >/dev/null 2>&1; then
  echo "the colima VM is running"

  # colima points docker at the VM by setting a context, and the context is the
  # only way the CLI knows where the daemon is.
  context="$(docker context show 2>/dev/null || true)"

  if [ "$context" != colima ]; then
    echo "warning: docker's context is ${context:-unset} rather than colima, so" >&2
    echo "the CLI is not pointed at this VM. 'docker context use colima' settles" >&2
    echo "it." >&2
  fi
else
  echo
  echo "warning: the colima VM is not running." >&2

  fatal="$(tail -n 40 "$log" 2>/dev/null | grep 'level=fatal' | tail -1 || true)"
  if [ -n "$fatal" ]; then
    echo "  $fatal" >&2
  fi

  echo "It may still be pulling its image. 'colima status' and $log" >&2
  echo "say where it is." >&2
fi
