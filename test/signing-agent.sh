#!/bin/bash

# The signing key and its agent, driven end to end with 1Password stubbed out: a
# key generated here, a stub op that serves its two halves, and then the real
# signing-key.sh, the real plist and the real wrapper. What it proves is the part
# that matters — that a commit signs with a key no file on the machine holds.
#
# Everything runs against a throwaway HOME, which is why the paths in the plist are
# rendered rather than left to $HOME: launchd hands a job the account's home
# directory, so a wrapper that read $HOME would look for the token in the wrong one
# and this suite could not exist.
#
# To add a case, add a check line: a description and a shell snippet that exits
# non-zero when the expectation is not met.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

label=io.github.timche.ssh-agent
uid="$(id -u)"

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

# launchd keys a job by label per account, so bootstrapping this one on the Mac
# would bounce the agent holding the real signing key — and it is loaded from a
# plist naming paths that are about to be deleted.
if [ "${CI:-}" != true ] && [ "${MACOS_SETUP_TEST_ANYWAY:-}" != 1 ]; then
  echo "signing-agent.sh loads a LaunchAgent labelled $label, which is the same" >&2
  echo "label the real agent uses — run it on a throwaway machine, or set" >&2
  echo "MACOS_SETUP_TEST_ANYWAY=1 if you are certain." >&2
  exit 1
fi

# Outside TMPDIR and short, because the agent socket lives inside this directory
# and a unix socket path runs out at about a hundred characters — the per-user
# TMPDIR macOS hands out is long enough for that to matter.
work="$(mktemp -d /tmp/macos-setup-test.XXXXXX)"
home="$work/home"
socket="$home/.ssh/agent.sock"

was_loaded=false
launchctl print "gui/$uid/$label" >/dev/null 2>&1 && was_loaded=true

wrapper_pid=""

cleanup() {
  if [ -n "$wrapper_pid" ]; then
    kill "$wrapper_pid" >/dev/null 2>&1
  fi

  # Only what this run loaded. A Mac that had the agent already is one this suite
  # refused to run on, but the check costs nothing and the mistake is expensive.
  if [ "$was_loaded" = false ]; then
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
  fi

  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$home"

# The key 1Password is standing in for, which nothing may end up writing to disk
# inside $home.
ssh-keygen -q -t ed25519 -N '' -C 'test signing key' -f "$work/key"

mkdir -p "$work/bin"
cat >"$work/bin/op" <<STUB
#!/bin/bash

# Two fields of one item, and a service-account token it insists on being handed:
# carrying that token from the file through launchd into op is half of what this
# suite is testing, and a stub that ignored it would pass without it.
if [ -z "\${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  echo "stub op: no service account token in the environment" >&2
  exit 1
fi

case "\${1:-} \${2:-}" in
  "read op://Claude/SSH Key/private key?ssh-format=openssh") exec cat "$work/key" ;;
  "read op://Claude/SSH Key/public key") exec cat "$work/key.pub" ;;
esac

echo "stub op: unexpected: \$*" >&2
exit 1
STUB
chmod 755 "$work/bin/op"

# In front of Homebrew's, which is why nothing in the scripts re-prepends the brew
# prefix to a PATH that already reaches it.
export PATH="$work/bin:$PATH"

install -d -m 700 "$home/.config/op"
printf 'ops_stub_token' >"$home/.config/op/service-account-token"
chmod 600 "$home/.config/op/service-account-token"

# What claude-dotfiles' .gitconfig carries on the real machine: the signing key is
# named by its public half alone, and the principal in allowed_signers has to be
# the address the commits are authored under.
HOME="$home" git config --global user.name "Test Signer"
HOME="$home" git config --global user.email signer@example.com
HOME="$home" git config --global gpg.format ssh
HOME="$home" git config --global user.signingkey "$home/.ssh/claude.pub"
HOME="$home" git config --global gpg.ssh.allowedSignersFile "$home/.ssh/allowed_signers"
HOME="$home" git config --global commit.gpgsign true

echo "--- claude/signing-key.sh"
if ! HOME="$home" "$root/claude/signing-key.sh"; then
  echo "  FAIL  signing-key.sh exited non-zero"
  failures=$((failures + 1))
fi

export home socket work label uid

# GitHub and the trust list both keep the type and the body and drop the comment.
export signer_line="signer@example.com $(awk '{print $1" "$2}' "$work/key.pub")"

check "the public half came out of 1Password" \
  'cmp -s "$work/key.pub" "$home/.ssh/claude.pub"'
check "the key is trusted under the authoring address" \
  'grep -qxF "$signer_line" "$home/.ssh/allowed_signers"'

# The whole point of the 1Password half: the private key is in a process and
# nowhere else. A grep rather than a name, because what must not be there is the
# content and not a particular path.
check "no private key was written anywhere in .ssh" \
  '! grep -rlq "PRIVATE KEY" "$home/.ssh"'
check "no private key was written beside the public half" \
  '[ ! -e "$home/.ssh/claude" ]'

export plist="$home/Library/LaunchAgents/$label.plist"

check "the agent plist was rendered" '[ -f "$plist" ]'
check "the plist is valid" 'plutil -lint "$plist"'
check "the plist kept no placeholder" '! grep -q "__" "$plist"'
check "the plist runs the copy of the wrapper, not the one in the repo" \
  '[ "$(plutil -extract ProgramArguments.0 raw -o - "$plist")" = "$home/.ssh/agent.sh" ]'
check "the wrapper is the one in the repo" \
  'cmp -s "$root/launchd/agent.sh" "$home/.ssh/agent.sh"'
check "the plist's PATH reaches op" \
  'plutil -extract EnvironmentVariables.PATH raw -o - "$plist" | grep -q "^$work/bin:"'
check "the plist names the socket and the token file" \
  '[ "$(plutil -extract EnvironmentVariables.AGENT_SOCKET raw -o - "$plist")" = "$socket" ] &&
   [ "$(plutil -extract EnvironmentVariables.OP_SERVICE_ACCOUNT_TOKEN_FILE raw -o - "$plist")" = \
     "$home/.config/op/service-account-token" ]'
check "launchd restarts the agent whenever it exits" \
  'plutil -extract KeepAlive xml1 -o - "$plist" | grep -q "<true/>"'

# A runner may have no console login and therefore no gui domain to load an agent
# into, which is the same thing that stops boswell loading over SSH against a Mac
# at its login window. The wrapper is what is being tested either way, so it is run
# directly when launchd would not.
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
  echo "  ok    the agent loaded into gui/$uid"
else
  echo "  --    no gui/$uid domain here; running the wrapper directly instead"

  HOME="$home" \
    AGENT_SOCKET="$socket" \
    OP_SERVICE_ACCOUNT_TOKEN_FILE="$home/.config/op/service-account-token" \
    "$home/.ssh/agent.sh" >"$work/agent.log" 2>&1 &
  wrapper_pid=$!
fi

# The key comes through a network call on a real Mac, so neither path has it the
# moment the job starts.
waited=0
while [ "$waited" -lt 30 ]; do
  if SSH_AUTH_SOCK="$socket" ssh-add -l >/dev/null 2>&1; then
    break
  fi
  sleep 1
  waited=$((waited + 1))
done

export fingerprint="$(ssh-keygen -lf "$work/key.pub" | awk '{print $2}')"

check "the agent is listening on the socket the dotfiles name" '[ -S "$socket" ]'
check "the agent holds the key from 1Password" \
  'SSH_AUTH_SOCK="$socket" ssh-add -l | grep -qF "$fingerprint"'

# The assertion the rest is for: git signs with a public key and an agent, and
# verifies against the trust list signing-key.sh wrote.
check "a commit signs through the agent and verifies" \
  'mkdir -p "$work/repo" && cd "$work/repo" && HOME="$home" git init -q . &&
   HOME="$home" SSH_AUTH_SOCK="$socket" git commit --allow-empty -q -m signed &&
   [ "$(HOME="$home" SSH_AUTH_SOCK="$socket" git log --format=%G? -1)" = G ]'

# Documented as safe to re-run, so prove it: nothing may be rewritten, and the
# agent has to come out of it holding the same key.
echo "--- claude/signing-key.sh again"
if ! HOME="$home" "$root/claude/signing-key.sh"; then
  echo "  FAIL  signing-key.sh is not idempotent"
  failures=$((failures + 1))
fi

check "the key still verifies after a second run" \
  'cd "$work/repo" &&
   HOME="$home" SSH_AUTH_SOCK="$socket" git commit --allow-empty -q -m again &&
   [ "$(HOME="$home" SSH_AUTH_SOCK="$socket" git log --format=%G? -1)" = G ]'
check "the trust list did not collect a second copy of the key" \
  '[ "$(wc -l <"$home/.ssh/allowed_signers")" -eq 1 ]'

if [ "$failures" -gt 0 ]; then
  echo "  $failures check(s) failed"
  [ -f "$work/agent.log" ] && sed 's/^/  /' "$work/agent.log"
  exit 1
fi
