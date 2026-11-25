#!/bin/bash
# Pre-push: refuse to push while other pull requests are open.
# Every open PR (Dependabot included) must be handled first: merged, fixed or closed.
# Pushing the branch of an open PR stays allowed, so that PR can be updated.
# Emergency bypass: git push --no-verify

set -euo pipefail

branch="${PRE_COMMIT_REMOTE_BRANCH:-}"
branch="${branch#refs/heads/}"

if ! command -v gh >/dev/null 2>&1; then
    echo "pre-push: the GitHub CLI (gh) is required to check open pull requests." >&2
    exit 1
fi

# The rule binds maintainers; contributors pushing to a fork are not blocked by others' PRs.
case "$(gh repo view --json viewerPermission --jq .viewerPermission 2>/dev/null || true)" in
    ADMIN|MAINTAIN|WRITE) ;;
    "") echo "pre-push: could not read repository permissions (gh auth or network)." >&2; exit 1 ;;
    *) exit 0 ;;
esac

if ! open_prs=$(gh pr list --state open --limit 200 --json number,title,headRefName \
    --jq ".[] | select(.headRefName != \"$branch\") | \"#\(.number) \(.title)\""); then
    echo "pre-push: could not list open pull requests (gh auth or network)." >&2
    exit 1
fi

[ -z "$open_prs" ] && exit 0

echo "pre-push: handle these open pull requests before pushing (merge, fix or close):" >&2
while IFS= read -r pr; do echo "  $pr" >&2; done <<< "$open_prs"
exit 1
