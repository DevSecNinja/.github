#!/bin/bash
# Post-create script for the devcontainer.
# Called by devcontainer.json postCreateCommand after the container is built.

set -euo pipefail

########################################
# Chezmoi — dotfiles manager
########################################
chezmoi_installer=$(curl -fsLS https://get.chezmoi.io) || true
sh -c "${chezmoi_installer}" -- init --apply DevSecNinja

########################################
# Mise — tool version manager
########################################
curl https://mise.run | sh
# shellcheck disable=SC2016 # Intentionally single-quoted to defer expansion to .bashrc
echo 'eval "$(~/.local/bin/mise activate bash)"' >>~/.bashrc
~/.local/bin/mise install

########################################
# Lefthook — git hooks
########################################
~/.local/bin/mise exec -- lefthook install
