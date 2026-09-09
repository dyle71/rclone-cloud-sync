#!/usr/bin/env bash
#
# Guard against committing anything personal to a public repository.
#
# Scans the tracked files and, with --history, every commit as well.  Meant to
# run before a release and as a pre-commit hook:
#
#     ln -s ../../tools/check-no-private-data.sh .git/hooks/pre-commit
#
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# Patterns that must never appear in a public checkout.  Extend for your own
# usernames, hostnames, employer and email domains before publishing a fork.
PATTERNS=(
    '/home/[a-z]'          # absolute home directories of a real user
    '/Users/[a-z]'         # the macOS equivalent
    '@[a-z0-9.-]+\.(at|com|net|org|de)'   # email addresses and tenant domains
    # Credentials, matched in the shape rclone and OAuth actually store them,
    # so identifiers like refresh_tokens() or find_pair(token: str) do not trip
    # the check.  In an rclone.conf the credential line assigns a JSON object
    # to a key named after the token, which is the shape matched below.
    'token[[:space:]]*=[[:space:]]*[{"]'
    '"(access|refresh)_token"'
    'client_secret[[:space:]]*=[[:space:]]*[^[:space:]]'
    'drive_id[[:space:]]*=[[:space:]]*[A-Za-z0-9]'
    'BEGIN [A-Z ]*PRIVATE KEY'
)

# Paths where a match is legitimate: this file lists the patterns themselves,
# and the example config documents ~/... paths (which are not absolute).
EXCLUDE_PATHS=('tools/check-no-private-data.sh')

fail=0

scan_worktree() {
    local file pattern hit
    while IFS= read -r file; do
        for skip in "${EXCLUDE_PATHS[@]}"; do
            [[ "$file" == "$skip" ]] && continue 2
        done
        for pattern in "${PATTERNS[@]}"; do
            hit=$(grep -nEI "$pattern" -- "$file" 2>/dev/null) || continue
            printf 'FAIL  %s\n      pattern: %s\n%s\n\n' "$file" "$pattern" "$hit"
            fail=1
        done
    done < <(git ls-files)
}

scan_history() {
    local pattern hit
    for pattern in "${PATTERNS[@]}"; do
        hit=$(git log --all -p --no-color | grep -nE "^\+.*$pattern" | head -20)
        if [[ -n "$hit" ]]; then
            printf 'FAIL  pattern %-40s (in history)\n%s\n\n' "$pattern" "$hit"
            fail=1
        fi
    done
}

echo "Scanning tracked files…"
scan_worktree

if [[ "${1:-}" == "--history" ]]; then
    echo "Scanning commit history…"
    scan_history
fi

if (( fail )); then
    echo "Private data found - do not publish."
    exit 1
fi
echo "Clean."
