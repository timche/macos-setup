# macOS Setup

[![test](https://github.com/timche/macos-setup/actions/workflows/test.yml/badge.svg)](https://github.com/timche/macos-setup/actions/workflows/test.yml)

Provisioning for a headless Apple Silicon Mac, and optionally for the one that runs Claude Code. As the account the machine is for, which unlike a VM's already exists:

```sh
curl -fsSL https://raw.githubusercontent.com/timche/macos-setup/main/bootstrap.sh | bash            # a plain Mac
curl -fsSL https://raw.githubusercontent.com/timche/macos-setup/main/bootstrap.sh | bash -s claude  # the same, plus Claude Code
```

A fresh Mac has no git and no package manager, so there is nothing to clone this with — which is what `bootstrap.sh` is for. It installs Homebrew, which installs the Xcode command line tools on the way through `softwareupdate` rather than the dialog nobody is in front of, clones this repo to `~/macos-setup` and runs `machine.sh` as the account you are logged in as. The second form runs `claude.sh` on top, and that is the whole of the difference.

The clone stays, unlike `debian-setup`'s, because a Mac is a machine you pull and re-run rather than one you reprovision from a URL:

```sh
git -C ~/macos-setup pull
~/macos-setup/machine.sh
~/macos-setup/claude.sh
```

Nothing installed from it points back into it, so it can be moved or deleted; `MACOS_SETUP_DIR` puts it somewhere else.

Both halves are safe to re-run, and both are careful about what is already there. That is the difference from provisioning a VM: this Mac was reachable over SSH and on the tailnet before the repo existed, because that is how the repo got onto it, and a second tailscale or a rewritten sshd would be a step backwards rather than a fresh start.

## The machine

`machine.sh` installs Homebrew and the four packages the rest depends on, turns Remote Login on if it is off, sets the machine to restart after power loss and never sleep, installs tailscale if there is none, puts docker on the Mac as a colima VM, hardens sshd down to keys only, no root, one user, and — only where there is a terminal to type an Apple ID at — installs Xcode.

Three things it deliberately does not do, all for the same reason — they need somebody looking at the screen, which on a headless Mac means Screen Sharing:

- **Auto-login.** It only checks, and says so when the account that logs in is not the one running the script. This matters more than it looks: a LaunchAgent lives in the `gui/<uid>` domain, which exists only while somebody is logged in at the console, so a Mac sitting at its login window is a Mac where neither docker nor anything the Claude half installs is running. Turning it on means writing the account password to `/etc/kcpassword`, obfuscated rather than encrypted, and that is a decision for whoever owns the Mac rather than for a script. It needs FileVault off.
- **The tailscale system extension**, which has to be allowed once in System Settings before anything routes.
- **Signing in to the tailnet**, which is the app's own flow.

`harden-ssh.sh` refuses to disable password logins unless the user has a key sshd could actually let them in with, because on a Mac there is no provider console to fall back to. A Mac reached with a password comes out of a run unhardened and told what to do about it. `FORCE_HARDEN=true` overrides that if you are certain of another way in.

## Docker

`docker.sh` installs colima, the docker CLI and the compose and buildx plugins, writes the shape of a Linux VM into colima's profile config, and hands the starting of that VM to `brew services` so that it comes back with the machine. There is no Docker Desktop here: that is an app, with an installer that expects somebody at the screen and a licence to go with it, where colima is a CLI that starts a VM and gets out of the way.

The VM is Virtualization.framework — `vmType: vz` — with Rosetta on, which is what runs an amd64 image at close to native speed. It gets every core but two and half the memory, both read from the hardware so that a different Mac needs no edit, and a 100GiB disk, which is a ceiling rather than a reservation because the image is sparse.

`brew services` means a LaunchAgent, and a LaunchAgent lives in the `gui/<uid>` domain — so docker is running only once the Mac has logged itself in, exactly like the agent holding the signing key. A Mac at its login window has no docker.

To see where it is:

```sh
colima status                                # the VM, and the socket docker talks to
docker context show                          # colima, the context colima sets when it starts
docker run --rm hello-world
brew services list                           # whether the LaunchAgent is loaded
tail -f /opt/homebrew/var/log/colima.log     # why the VM did not come up
```

The VM, its disk, its images and its volumes are all under `~/.colima`, and nothing outside it belongs to docker. `colima delete` starts over, and is also how all of that is lost.

To resize it, edit `~/.colima/default/colima.yaml` and restart — `colima stop && colima start --edit` does both. That file is the one `docker.sh` writes, and colima rewrites it in its own fully commented form on the first start. `cpu` and `memory` take effect at the next start and a disk can grow, but a disk cannot shrink and `vmType` and `mountType` are fixed when the VM is created, so changing either of those means deleting the VM. Re-running `docker.sh` resizes nothing: it reports where the config and the hardware disagree and leaves whatever is there alone.

## Xcode

`xcode.sh` installs the full Xcode, which this Mac needs for signing builds of meru with a Developer ID certificate — the command line tools Homebrew brought are enough to compile but not the whole toolchain electron-builder reaches for. It is the one step of the machine `machine.sh` will not do unattended: Apple hands nobody an Xcode without an Apple ID, a 2FA code typed in while it is still valid, and the account password for the privileged end of the install. `machine.sh` runs it when there is a terminal and lists it under what is left when there is not.

```sh
~/macos-setup/xcode.sh
```

It stops before downloading anything if `/` has less than 40GB free, since the xip is around 11GB and unpacks to more than twice that before the copy into `/Applications`. The download comes through [`xcodes`](https://github.com/XcodesOrg/xcodes) — `--latest`, so a release and never a beta — and then the script selects what it installed, accepts the licence and runs the first launch, each one guarded so that a re-run asks for nothing.

`xcodes` remembers the Apple ID and keeps its password in the login keychain. This Mac is reached over SSH, where a keychain that needs to ask for anything cannot, so that write may be refused — in which case xcodes says so and asks for the Apple ID again next time, `XCODES_USERNAME` and `XCODES_PASSWORD` in the environment answer it without a keychain at all, and `xcodes signout` clears whatever is stored.

To see where it is:

```sh
xcode-select -p        # /Applications/Xcode-<version>.app/Contents/Developer
xcodebuild -version
xcodes installed       # every Xcode on the Mac, and which one is selected
```

Signing needs one thing `xcode.sh` has no business fetching: the Developer ID certificate and its private key in the login keychain, imported from wherever it is kept with `security import <certificate>.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`.

## The Claude Code overlay

`claude.sh` installs nothing — every package is Homebrew's and Homebrew is the machine's. What it does is the part that needs an account: it logs in to GitHub and to Claude Code, installs the commit-signing key, and hands over to the private `claude-dotfiles` for everything after that — the shell, the prompt, the runtimes and `~/.claude`. Run it against a Mac `machine.sh` has already built, and rerun it when a token expires.

The GitHub token goes in a file rather than the login keychain (`gh auth login --insecure-storage`). This Mac is reached over SSH and does its work from LaunchAgents, and both of those meet a keychain that will not answer with a prompt nobody sees. Claude Code keeps its own credential in the keychain and falls back to `~/.claude/.credentials.json` when the write is refused, which is what an SSH session usually gets; if the login does not take, `claude setup-token` prints a token that lasts a year and `CLAUDE_CODE_OAUTH_TOKEN` carries it instead.

## The signing key

The key is the same one every machine here signs with, and it lives in 1Password. Only its public half is ever written to this Mac — `~/.ssh/claude.pub`, which `claude-dotfiles`' `.gitconfig` points `user.signingkey` at, plus a line in `~/.ssh/allowed_signers` so git can verify what it signs. The private half is read out of 1Password straight into an ssh-agent, over a pipe, every time that agent starts. There is no file to leak and nothing to paste.

What it expects:

- A 1Password item with the key in it, at `op://Claude/SSH Key`, whose `private key` and `public key` fields are the two halves. `SIGNING_KEY_OP_ITEM` names a different one.
- A 1Password service account with read access to that vault. `claude/signing-key.sh` asks for its token once, without echoing it, checks it can read the item, and stores it in `~/.config/op/service-account-token` for the agent to read at every start.

The agent is a LaunchAgent, `io.github.timche.ssh-agent`, running `~/.ssh/agent.sh`: it starts an `ssh-agent` on a fixed socket at `~/.ssh/agent.sock`, loads the key into it, and then waits on it, so that launchd restarting the pair is also what re-reads the key. The socket is fixed because the one launchd hands out belongs to the agent macOS starts for each session, which holds nothing of this and is not visible to an SSH login at all — `claude-dotfiles`' `.zshenv` and its own LaunchAgents name `~/.ssh/agent.sock` instead. At boot the key cannot be read until the network is up, so the agent comes up empty and keeps trying with a widening delay.

To see where it is:

```sh
launchctl print gui/$(id -u)/io.github.timche.ssh-agent   # loaded, and what launchd makes of it
SSH_AUTH_SOCK=~/.ssh/agent.sock ssh-add -l                # the key, or nothing yet
tail -f ~/Library/Logs/ssh-agent.log                      # why it is nothing yet
git commit --allow-empty -m test && git log --format='%G?' -1
```

An `invalid format` from git rather than a `G` usually means exactly one thing: the agent does not hold the key, and `ssh-keygen -Y sign` has fallen back to reading the public key as a private one.

## Two things worth knowing

The tailnet is the way in, and sshd is what answers on it: tailscaled does not serve SSH on a Mac the way it does on Linux, so the drop-in `harden-ssh.sh` installs governs every connection and there is no second door but Screen Sharing. The tailnet's own policy is what decides who gets that far.

macOS reads `sshd_config` per connection — launchd holds port 22 and spawns an sshd per client — so there is nothing to restart after the drop-in lands, and a config it cannot parse breaks the next login rather than waiting for one. That is why the drop-in is checked with `sshd -t` and taken straight back out if it does not hold up.

## Environment knobs

`MACOS_SETUP_REPO`, `MACOS_SETUP_DIR`, `CLAUDE_DOTFILES_REPO`, `CLAUDE_DOTFILES_DIR`, `SIGNING_KEY_OP_ITEM`, `OP_SERVICE_ACCOUNT_TOKEN_FILE`, `FORCE_HARDEN`.

`CLAUDE.md` has the details: the order the scripts run in, the constraints that are not obvious from reading them, and how to test.
