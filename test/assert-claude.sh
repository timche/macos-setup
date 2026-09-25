#!/bin/bash

# Assertions against a Mac claude.sh has just finished with. Runs on the machine
# itself; see assert.sh for the generic half this sits on top of.
#
# A runner has no authenticated gh, no 1Password service account and no terminal,
# so claude.sh gets as far as checking what machine.sh left and no further: the
# dotfiles are never cloned and nothing is ever logged in. What is asserted here is
# that every step of it skips rather than failing, or worse, sitting on a prompt.
# The signing key and its agent are driven with a stub op in signing-agent.sh.
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

# Nothing is logged in here, which is the state every fresh Mac is in. timeout on
# the ones that would otherwise open a browser flow, because that failure mode is a
# hang rather than an exit status.
check "install.sh skips the handover without a token" \
  '"$root/claude/install.sh"'
check "login.sh exits without a terminal" \
  '"$root/claude/login.sh" < /dev/null'
check "signing-key.sh exits without a terminal or a stored token" \
  'OP_SERVICE_ACCOUNT_TOKEN_FILE="$(mktemp -u)" "$root/claude/signing-key.sh" < /dev/null'
check "register-signing-key.sh skips when gh cannot help" \
  '"$root/claude/register-signing-key.sh"'

check "the dotfiles were not cloned without a token" \
  '[ ! -d "$HOME/.claude-dotfiles" ]'

# Rendered by sed at install time, so a stray character is a file launchd rejects
# at load with nothing in it to say why.
check "the agent template is a valid plist" \
  'plutil -lint "$root/launchd/io.github.timche.ssh-agent.plist"'

# The wrapper is copied to ~/.ssh and run by launchd, neither of which would say
# why a syntax error stopped it.
check "every script parses" \
  'find "$root" -name "*.sh" -not -path "*/.git/*" -exec bash -n {} +'

if [ "$failures" -gt 0 ]; then
  echo "  $failures check(s) failed"
  exit 1
fi
