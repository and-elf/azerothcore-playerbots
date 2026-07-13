#!/usr/bin/env bash
#
# install-modules.sh — clone/update the AzerothCore modules into ./modules/.
#
# Modules are independent git repos (NOT submodules): each is cloned into
# modules/<name> at a pinned branch. This replaces the submodule "pinned manifest"
# — this file IS the manifest. Re-runnable: existing clones are fetched and
# fast-forwarded; missing ones are cloned.
#
# Run from the core repo root:  ./install-modules.sh
#
set -euo pipefail

# name  url  branch  (whitespace-separated; keep columns readable)
MODULES=(
  "mod-branding            git@github.com:and-elf/mod-branding.git             master"
  "mod-branded-bots        git@github.com:and-elf/mod-branded-bots.git         master"
  "mod-branded-mercenary   git@github.com:and-elf/mod-branded-mercenary.git    feat/fragment-branding-hire"
  "mod-dungeon-questgivers git@github.com:and-elf/mod-dungeon-questgivers.git  master"
  # --- Disabled: no server adapter yet, so they break the worldserver link.
  #     Re-enable each once it defines Addmod_<name>Scripts() and builds clean.
  #   "mod-reforge             git@github.com:and-elf/mod-reforge.git              master"   # draft (#76)
  #   "mod-cinematics          git@github.com:and-elf/mod-cinematics.git           main"     # multi-file API drift vs core
  "mod-learn-spells        https://github.com/azerothcore/mod-learn-spells.git  master"
  # External — MUST stay in lockstep with the playerbots CORE branch you build against.
  "mod-playerbots          https://github.com/liyunfan1223/mod-playerbots.git  master"
  # Adopted upstream AzerothCore modules (used ~as-is; see README "Reference / adopted modules").
  "mod-eluna               https://github.com/azerothcore/mod-eluna.git         master"
  "mod-ah-bot              https://github.com/azerothcore/mod-ah-bot.git         master"
  "mod-rdf-expansion       https://github.com/azerothcore/mod-rdf-expansion.git  master"
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODDIR="$ROOT/modules"
mkdir -p "$MODDIR"

for entry in "${MODULES[@]}"; do
  read -r name url branch <<<"$entry"
  dest="$MODDIR/$name"
  if [ -d "$dest/.git" ]; then
    echo ">> updating $name ($branch)"
    git -C "$dest" fetch --quiet origin "$branch"
    git -C "$dest" checkout --quiet "$branch"
    git -C "$dest" merge --ff-only --quiet "origin/$branch"
  else
    echo ">> cloning  $name ($branch)"
    git clone --quiet --branch "$branch" "$url" "$dest"
  fi
done

echo "Done. ${#MODULES[@]} modules ready in modules/."
