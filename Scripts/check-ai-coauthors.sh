#!/bin/bash
#
# Fails if any commit, or the pull request description, credits an AI tool
# as a co-author. AI tools may assist, but must not be credited as authors.
# See AI_POLICY.md.
#
# Usage:
#   Scripts/check-ai-coauthors.sh [commit-range]
#
#   commit-range  Commits to check. Defaults to origin/main..HEAD.
#   PR_BODY       Optional environment variable holding the PR description.
#
# Examples:
#   Scripts/check-ai-coauthors.sh
#   Scripts/check-ai-coauthors.sh main..feature/my-branch

set -euo pipefail

# Names that identify an AI tool in a Co-authored-by trailer (case-insensitive).
# Human co-authors are allowed.
AI_TOOLS=(
  "claude"
  "anthropic"
  "copilot"
  "openai"
  "chatgpt"
  "codex"
  "cursor"
  "gemini"
  "devin"
  "aider"
  "windsurf"
  "codeium"
  "tabnine"
  "amazon q"
)

COMMIT_RANGE="${1:-origin/main..HEAD}"
PR_BODY="${PR_BODY:-}"

# Joins AI_TOOLS into one regex alternation, e.g. "claude|anthropic|...".
build_pattern() {
  local IFS="|"
  echo "^[[:space:]]*co-authored-by:.*(${AI_TOOLS[*]})"
}

PATTERN="$(build_pattern)"

# Prints the lines of stdin that are AI co-author trailers.
find_ai_trailers() {
  grep -iE "$PATTERN" || true
}

# Reports an error, as a GitHub Actions annotation when running in CI.
report_error() {
  local message="$1"
  local offending_lines="$2"

  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::${message}"
  else
    echo "error: ${message}"
  fi

  echo "$offending_lines" | sed 's/^/    /'
}

found_violation=false

# Check every commit message in the range.
for sha in $(git rev-list "$COMMIT_RANGE"); do
  trailers="$(git log -1 --format=%B "$sha" | find_ai_trailers)"

  if [ -n "$trailers" ]; then
    short_sha="$(git rev-parse --short "$sha")"
    report_error "Commit ${short_sha} credits an AI tool as co-author:" "$trailers"
    found_violation=true
  fi
done

# Check the pull request description, if one was given.
trailers="$(echo "$PR_BODY" | find_ai_trailers)"

if [ -n "$trailers" ]; then
  report_error "The PR description credits an AI tool as co-author:" "$trailers"
  found_violation=true
fi

if [ "$found_violation" = true ]; then
  echo
  echo "AI tools may assist, but must not be credited as authors."
  echo "Remove these trailers (for example with 'git rebase -i' and"
  echo "'git commit --amend'), then push again. See AI_POLICY.md."
  exit 1
fi

echo "No AI co-author trailers found in ${COMMIT_RANGE}."
