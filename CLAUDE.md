# CLAUDE.md

Machine provisioning for a headless Apple Silicon Mac, with an optional overlay that turns it into the one Claude Code runs on. Shell scripts only — no build, no lint, no package manager. Every script opens with a comment explaining why it exists and what would break if it ran elsewhere in the order, so read the script rather than looking for a second copy of it here.

The sibling is [timche/debian-setup](https://github.com/timche/debian-setup), which does the same for a VM and which this repo mirrors deliberately: the same two-entry-point shape, the same split between what works before you can authenticate and what needs an account, the same handover to the private `claude-dotfiles`. Where the two differ, the difference is macOS's rather than a preference, and the script says so.

Two entry points. `bootstrap.sh` is the one a Mac with nothing on it has: a fresh Mac has no git to clone with, so it installs Homebrew — which brings the Xcode command line tools through `softwareupdate` rather than the dialog — clones the repo and hands to `machine.sh`, then to `claude.sh` if it was given the one argument it takes, `claude`. Anything else is an error, so a typo cannot quietly produce a generic Mac. Unlike `provision.sh` on the VM it never runs as root: there is no account to create, and Homebrew refuses root outright.

`machine.sh` refuses root and calls `bootstrap-system.sh`, `remote-login.sh`, `unattended.sh`, `tailscale.sh`, `docker.sh`, `harden-ssh.sh` in that order, then `xcode.sh` last and only where there is a terminal — Xcode is an 11GB download behind an Apple ID and a 2FA code, so a run with nobody watching lists it as left to do instead. That is the whole of the machine, and none of it needs an account anywhere: the Apple ID Xcode wants belongs to the App Store rather than to anything this repo installs.

`claude.sh` is the overlay and the second entry point. It installs nothing — every package is `bootstrap-system.sh`'s — and calls `claude/install.sh`, `claude/login.sh` and `claude/signing-key.sh` in that order: the dotfiles need a token, the token comes from the login, and the signing key needs the `user.email` the dotfiles carry. `claude/signing-key.sh` calls `claude/ssh-agent.sh` for the agent that holds the private half and `claude/register-signing-key.sh` for the public one, which `claude/install.sh` also calls once there is a token to register with.

Public, and holds nothing personal — the shell, the runtimes and `~/.claude` come from the private `claude-dotfiles`, which `claude/install.sh` clones once `gh` is logged in.

## Committing

Commit and push to main directly, no branch and no PR. Standing permission, and an exception to the global rules on branching and asking before a push.

## Rules

- Everything checks before it changes. This is the rule the VM's repo does not need: that box is provisioned from bare metal, while this Mac was on the tailnet and answering SSH before this repo existed, because that is how the repo got onto it. A step that installs a second tailscale, rewrites an sshd its owner configured, or reboots a machine somebody is working on is a regression even when it is idempotent.
- The generic half may not depend on the Claude half. `machine.sh` and everything it calls must leave a usable Mac with no account anywhere, and must not name `claude.sh` or anything under `claude/`. Only `bootstrap.sh` knows both exist.
- Nothing may be written for one account: paths go through `$HOME`, and the account record is `dscl`'s rather than `getent`'s, which macOS does not have. `test/assert.sh` fails on a literal `/Users/<name>` anywhere in the scripts, because CI runs as `runner` and the Mac is `timche`.
- `/bin/bash` on a Mac is 3.2, which is what every script here runs under. No associative arrays, and no reading an empty array under `set -u` — it is an unbound variable there.
- launchd expands neither `~` nor `$HOME`, and the `HOME` it hands a job is the account's rather than the one that installed it. So every path a LaunchAgent needs is rendered into the plist at install time, including the socket and the token file the wrapper reads — `launchd/agent.sh` falls back to `$HOME` only for a run by hand. A plist whose keys have changed needs `launchctl bootout` and a fresh `bootstrap`; `kickstart` restarts the job from the copy launchd already read.
- The private half of the signing key never touches the disk. It goes from `op` down a pipe into `ssh-add` and exists in the agent's memory only. Nothing may write it, print it, or pass it as an argument — and the same goes for the service-account token that reads it.
- Prompts belong in a script that has checked for a terminal. Under the documented curl install stdin is the pipe feeding `bootstrap.sh`, which is why it hands each half `/dev/tty` when there is one; a step that would prompt without a terminal has to say what it skipped instead, or a provision with nobody watching hangs.
- Every brew package is the machine's, including the three the overlay is the only caller of. That is the one place this repo draws the line differently from the VM's, where `claude.sh` installs `gh` and `jq` itself: Homebrew is the machine, `claude-dotfiles`' installer stops with a message if it cannot find `brew`, and one package list beats two. `bootstrap-system.sh` holds that list; `tailscale.sh` and `docker.sh` install their own because each has to decide what is already there before it installs anything.
- Apple Silicon and macOS only, refused up front. `/opt/homebrew` is written into `claude-dotfiles`' PATH and into every plist, and an Intel Mac would come out of a run half working with nothing saying why.

## Testing

`.github/workflows/test.yml`, on a `macos-latest` runner, and nowhere else: there is no macOS container to put any of this in, and the suite changes the machine it runs on. It runs `machine.sh` twice with `test/assert.sh` after each, then `xcode.sh` twice — a runner arrives with several Xcodes, so what that exercises is the half of it that installs nothing — then `claude.sh` with `test/assert-claude.sh`, then `test/signing-agent.sh`, then `harden-ssh.sh` with a key seeded the way a real Mac has one.

`test/signing-agent.sh` is the one worth reading. It generates a key, puts a stub `op` in front of the real one on PATH, and runs the real `claude/signing-key.sh` against a throwaway `HOME` — then asserts that the agent holds the key, that nothing under `.ssh` contains a private one, and that a commit signs and verifies. It refuses to run outside CI unless `MACOS_SETUP_TEST_ANYWAY=1`, because launchd keys a job by label per account and loading it on the real Mac would bounce the agent holding the real key.

What CI cannot reach: a service account and a vault, a tailnet to log in to — the runner installs tailscaled and configures its prefs, which works logged out, but nothing authenticates and `assert.sh` says so — a machine that loses power, and TCC — the runners have SIP disabled, so anything gated on Full Disk Access behaves more permissively there than on a real Mac. That last one is why `remote-login.sh` goes through launchd rather than `systemsetup`, which is gated. Nor a hypervisor: a runner is a VM itself and Virtualization.framework inside one refuses outright with "Virtualization is not available on this hardware", with or without rosetta — so `docker.sh` installs and configures on a runner but its VM never boots, and `assert.sh` says which half of docker it therefore skipped rather than passing quietly.

## Environment knobs

`TS_ADVERTISE_ROUTES` (the subnet this Mac advertises, derived from the default route's interface when it is unset; set-but-empty advertises none), `MACOS_SETUP_REPO`, `MACOS_SETUP_DIR` (the clone, which stays — nothing points into it, but a Mac is pulled and re-run rather than reprovisioned from a URL), `CLAUDE_DOTFILES_REPO`, `CLAUDE_DOTFILES_DIR`, `SIGNING_KEY_OP_ITEM` (the 1Password item holding both halves of the key), `OP_SERVICE_ACCOUNT_TOKEN_FILE`, `FORCE_HARDEN`, `MACOS_SETUP_TEST_ANYWAY`.
