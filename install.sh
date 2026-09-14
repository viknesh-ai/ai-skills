#!/usr/bin/env bash
#
# Installs the skills in this repository into your personal Claude Code skills
# folder, so they are available in every repository you work on.
#
#   ./install.sh                  installs into ~/.claude/skills
#   ./install.sh /some/other/dir  installs somewhere else

set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$HOME/.claude/skills}"

mkdir -p "$DEST"
rm -rf "$DEST/pr-review"
cp -R "$SRC/code-review" "$DEST/pr-review"
chmod +x "$DEST/pr-review/pr-review.sh"

echo "Installed pr-review to $DEST/pr-review"
echo
echo "One more step - set your repository:"
echo "  $DEST/pr-review/config.json  ->  \"repo\": \"your-org/your-repo\""
