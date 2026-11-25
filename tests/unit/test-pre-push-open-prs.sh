#!/bin/bash
# Pre-push hook: refuses to push while other pull requests are open.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.githooks/pre-push-open-prs.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fake gh: applies the --jq filter to canned JSON (or fails when FAKE_GH_FAIL=1).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
[ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
if [ "$1" = repo ]; then printf '%s\n' "${FAKE_PERMISSION:-ADMIN}"; exit; fi
while [ $# -gt 0 ]; do [ "$1" = --jq ] && { printf '%s' "$FAKE_PRS" | jq -r "$2"; exit; }; shift; done
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

run_hook() { PRE_COMMIT_REMOTE_BRANCH="refs/heads/$1" bash "$HOOK" > "$WORK/out" 2>&1; }

export FAKE_PRS='[]'
run_hook feature || { echo 'FAIL: push blocked with no open PRs'; exit 1; }

export FAKE_PRS='[{"number":2,"title":"chore(deps): bump checkout","headRefName":"dependabot/x"}]'
if run_hook feature; then echo 'FAIL: push allowed with another open PR'; exit 1; fi
grep -q '#2 chore(deps): bump checkout' "$WORK/out" || { echo 'FAIL: blocking PR not listed'; exit 1; }

run_hook dependabot/x || { echo 'FAIL: updating the branch of the open PR was blocked'; exit 1; }

export FAKE_GH_FAIL=1
if run_hook feature; then echo 'FAIL: push allowed when open PRs could not be listed'; exit 1; fi

unset FAKE_GH_FAIL
FAKE_PERMISSION=READ run_hook feature || { echo 'FAIL: contributor without write access was blocked'; exit 1; }

echo 'ok pre-push open PR hook'
