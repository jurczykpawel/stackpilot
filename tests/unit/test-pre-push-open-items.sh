#!/bin/bash
# Pre-push hook: refuses to push while other pull requests or unhandled issues are open.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/.githooks/pre-push-open-items.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fake gh: applies the --jq filter to canned JSON (or fails when FAKE_GH_FAIL=1).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/bin/bash
[ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
if [ "$1" = repo ]; then printf '%s\n' "${FAKE_PERMISSION:-ADMIN}"; exit; fi
DATA=$FAKE_PRS
[ "$1" = issue ] && DATA=$FAKE_ISSUES
while [ $# -gt 0 ]; do [ "$1" = --jq ] && { printf '%s' "$DATA" | jq -r "$2"; exit; }; shift; done
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# A repository whose origin/main is the base of the pushed branch.
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
git -C "$REPO" checkout -q -b feature
commit() { git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }

run_hook() { (cd "$REPO" && PRE_COMMIT_REMOTE_BRANCH="refs/heads/$1" bash "$HOOK") > "$WORK/out" 2>&1; }

export FAKE_PRS='[]' FAKE_ISSUES='[]'
run_hook feature || { echo 'FAIL: push blocked with nothing open'; exit 1; }

export FAKE_PRS='[{"number":2,"title":"chore(deps): bump checkout","headRefName":"dependabot/x"}]'
if run_hook feature; then echo 'FAIL: push allowed with another open PR'; exit 1; fi
grep -q '#2 chore(deps): bump checkout' "$WORK/out" || { echo 'FAIL: blocking PR not listed'; exit 1; }
run_hook dependabot/x || { echo 'FAIL: updating the branch of the open PR was blocked'; exit 1; }
export FAKE_PRS='[]'

export FAKE_ISSUES='[{"number":7,"title":"Installer breaks"},{"number":8,"title":"Docs typo"}]'
if run_hook feature; then echo 'FAIL: push allowed with open issues'; exit 1; fi
grep -q '#7 Installer breaks' "$WORK/out" || { echo 'FAIL: blocking issue not listed'; exit 1; }

commit 'fix: installer (Closes #7)'
if run_hook feature; then echo 'FAIL: push allowed while #8 is still unhandled'; exit 1; fi
grep -q '#8 Docs typo' "$WORK/out" || { echo 'FAIL: remaining issue not listed'; exit 1; }
grep -q '#7' "$WORK/out" && { echo 'FAIL: issue closed by the pushed commits still listed'; exit 1; }

commit 'docs: mention #8 without closing it'
if run_hook feature; then echo 'FAIL: a bare mention counted as handling the issue'; exit 1; fi

commit 'docs: typo, fixes #8'
run_hook feature || { echo 'FAIL: push blocked although the pushed commits close every open issue'; exit 1; }

export FAKE_GH_FAIL=1
if run_hook feature; then echo 'FAIL: push allowed when GitHub could not be read'; exit 1; fi
unset FAKE_GH_FAIL

FAKE_PERMISSION=READ run_hook feature || { echo 'FAIL: contributor without write access was blocked'; exit 1; }

echo 'ok pre-push open items hook'
