#!/usr/bin/env bash
# Wire this repo's tracked hooks into git by pointing core.hooksPath at the
# hooks/ directory. No copying, no symlinks — the hooks stay version-controlled
# and every clone gets the same scan once this is run. Re-run any time; it's
# idempotent.
#
#   ./hooks/install.sh            # enable
#   ./hooks/install.sh --uninstall  # revert to the default .git/hooks
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [[ "${1:-}" == "--uninstall" ]]; then
    git config --unset core.hooksPath 2>/dev/null || true
    echo "✓ Removed core.hooksPath — git is back to .git/hooks."
    exit 0
fi

chmod +x hooks/pre-commit hooks/pre-push hooks/secret-scan.sh hooks/install.sh
git config core.hooksPath hooks

echo "✓ core.hooksPath → hooks/"
echo "  pre-commit : blocks staged secrets on every commit"
echo "  pre-push   : re-scans outgoing commits as a backstop"
echo
echo "Bypass once with --no-verify; allowlist false positives in hooks/secret-allow.txt."
echo "Heads up: --no-verify (and core.hooksPath) are local — add CI/server scanning"
echo "for an unbypassable layer."
