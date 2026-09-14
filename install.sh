#!/usr/bin/env bash
#
# Installs skills into .github/skills/ in the current repository.
#
#   ./install.sh                 install every skill in this repository
#   ./install.sh code-review     install just the ones you name
#
# It also runs straight from a URL, with no clone:
#
#   curl -fsSL <raw-url>/install.sh | bash
#   curl -fsSL <raw-url>/install.sh | bash -s -- code-review
#
# Override the destination with AI_SKILLS_DEST, for example
# AI_SKILLS_DEST=~/.config/skills to install for yourself rather than the repo.

set -euo pipefail

REPO="${AI_SKILLS_REPO:-viknesh-ai/ai-skills}"
BRANCH="${AI_SKILLS_BRANCH:-main}"
DEST="${AI_SKILLS_DEST:-.github/skills}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# A skill is any directory holding a SKILL.md.
find_skills() {
  find "$1" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | sort
}

# Use the checkout this script lives in when there is one; otherwise fetch the
# repository, so the same script works from a clone and from a curl pipe.
SRC=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  [[ -n "$(find_skills "$here")" ]] && SRC="$here"
fi

if [[ -z "$SRC" ]]; then
  command -v curl >/dev/null 2>&1 || die "curl is not installed."
  command -v tar >/dev/null 2>&1 || die "tar is not installed."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP" ||
    die "could not download $REPO@$BRANCH."
  SRC="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$SRC" ]] || die "the downloaded archive looks empty."
fi

# The skills named on the command line, or every skill in the repository.
names=()
if [[ $# -gt 0 ]]; then
  names=("$@")
else
  while IFS= read -r skill_md; do
    [[ -n "$skill_md" ]] || continue
    names[${#names[@]}]="$(basename "$(dirname "$skill_md")")"
  done < <(find_skills "$SRC")
fi

[[ ${#names[@]} -gt 0 ]] || die "no skills found in $REPO."

mkdir -p "$DEST"

for name in "${names[@]}"; do
  [[ -f "$SRC/$name/SKILL.md" ]] ||
    die "'$name' is not a skill in $REPO. Available: $(find_skills "$SRC" | while IFS= read -r m; do basename "$(dirname "$m")"; done | tr '\n' ' ')"

  rm -rf "${DEST:?}/$name"
  cp -R "$SRC/$name" "$DEST/$name"
  find "$DEST/$name" -name '*.sh' -exec chmod +x {} +
  printf 'Installed %s -> %s/%s\n' "$name" "$DEST" "$name"
done

printf '\nNext: set "repo" in %s/*/config.json to the repository you want reviewed.\n' "$DEST"
