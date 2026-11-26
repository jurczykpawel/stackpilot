#!/bin/bash
# Pre-push: refuse to push while pull requests or issues are left unhandled.
# - Every open PR other than the one for the pushed branch (Dependabot included) must be
#   merged, fixed or closed first.
# - Every open issue must be closed, or closed by the pushed commits ("Closes #N", "Fixes #N",
#   "Resolves #N" in a commit message), so merging the push closes it.
# Emergency bypass: git push --no-verify

set -euo pipefail

branch="${PRE_COMMIT_REMOTE_BRANCH:-}"
branch="${branch#refs/heads/}"
to_ref="${PRE_COMMIT_TO_REF:-HEAD}"

if ! command -v gh >/dev/null 2>&1; then
    echo "pre-push: the GitHub CLI (gh) is required to check open pull requests and issues." >&2
    exit 1
fi

# The rule binds maintainers; contributors pushing to a fork are not blocked by others' items.
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

if ! open_issues=$(gh issue list --state open --limit 200 --json number,title \
    --jq '.[] | "\(.number)\t\(.title)"'); then
    echo "pre-push: could not list open issues (gh auth or network)." >&2
    exit 1
fi

# Issues closed by the commits this push adds on top of the default branch.
default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
base=$(git merge-base "$to_ref" "$default" 2>/dev/null || true)
closed=" "
if [ -n "$base" ]; then
    closed+=$(git log --format=%B "$base..$to_ref" |
        grep -oiE '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#[0-9]+' | grep -oE '[0-9]+$' | tr '\n' ' ' || true)
fi

unhandled_issues=""
while IFS=$'\t' read -r number title; do
    [ -n "$number" ] || continue
    case "$closed" in *" $number "*) continue ;; esac
    unhandled_issues+="#$number $title"$'\n'
done <<< "$open_issues"

[ -z "$open_prs" ] && [ -z "$unhandled_issues" ] && exit 0

echo "pre-push: handle these first (merge, fix or close; an issue may also be closed by this push with 'Closes #N'):" >&2
while IFS= read -r item; do
    [ -n "$item" ] && echo "  $item" >&2
done <<< "$open_prs"$'\n'"$unhandled_issues"
exit 1
