# Every Homebrew package this Mac has, applied by bootstrap-system.sh with
# `brew bundle`. One declarative list rather than an array per script: Homebrew is
# the machine, and that includes the packages the Claude overlay is the only caller
# of. CLAUDE.md has the rule.
#
# bootstrap-system.sh passes --no-upgrade, so a re-run installs what is missing and
# moves no version. That matters more here than on a box you throw away: this Mac is
# reached over the very sshd and tailnet a run touches, and `brew upgrade tailscale`
# restarts the daemon the SSH session is riding on. `brew bundle upgrade` moves them
# when that is what is wanted.
#
# xcodes and aria2 are deliberately not here. Both exist only for the Xcode download,
# which is xcode.sh's and happens only where there is a terminal to type an Apple ID
# at — so declaring them would install two packages on every unattended provision for
# a step it is never going to run, and would turn aria2's absence from a slower
# download into a failed dependency.

# claude.sh clones a private repo with gh and reads the signing key out of 1Password
# with op; both it and docker.sh patch a config with jq. btop is the one that is only
# for whoever logs in to look at the machine.
brew "btop"
brew "gh"
brew "jq"

# The formula, not the cask of nearly the same name: the cask is the standalone app,
# and an app is a login item inside a GUI session, where tailscale.sh makes this a
# root system daemon that is up before anybody logs in.
brew "tailscale"

# docker on a Mac is a Linux VM and a CLI pointed into it. docker is the CLI alone —
# the daemon lives inside colima's VM — and Homebrew packages the two plugins
# separately from the CLI that loads them.
brew "colima"
brew "docker"
brew "docker-buildx"
brew "docker-compose"

# op, and the cask rather than a formula because 1Password ships the CLI itself. It is
# a zip with a binary in it these days, so nothing here needs sudo for it. Nothing
# declares `adopt`: brew bundle passes --adopt to every cask install of its own
# accord, which is what takes over a copy that arrived by another route instead of
# refusing to lay a cask over it.
cask "1password-cli"
