#!/bin/bash
# Hook: Enforce /ship before merging PRs
# Blocks `gh pr merge` unless /ship has verified the PR (marker file exists)
# Fast path: non-merge commands exit immediately without spawning node
set -e

INPUT=$(cat)

# Fast path: check if this is a gh pr merge command using bash string matching
# Avoid spawning node for the 99% of Bash calls that aren't merges
if ! echo "$INPUT" | grep -q "gh pr merge"; then
  exit 0
fi

# Parse the command and cwd from JSON using Node.js
PARSED=$(echo "$INPUT" | node -e "
let d='';
process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  try {
    const j=JSON.parse(d);
    const cmd = j.tool_input?.command || '';
    const cwd = j.cwd || '';
    console.log(cmd + '|||' + cwd);
  } catch { console.log('|||'); }
})")

COMMAND="${PARSED%%|||*}"
CWD="${PARSED##*|||}"

# Confirm this is actually a gh pr merge command (not just grep false positive)
if ! echo "$COMMAND" | grep -qE '^gh pr merge'; then
  exit 0
fi

# Extract PR number from command (e.g., "gh pr merge 123 --squash")
PR_NUMBER=$(echo "$COMMAND" | grep -oE 'gh pr merge [0-9]+' | grep -oE '[0-9]+')

# If no PR number in command, resolve from current branch (gh pr merge --squash uses branch PR)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(cd "$CWD" && gh pr view --json number -q .number 2>/dev/null)
fi

# If still no PR number, block -- can't verify without one
if [ -z "$PR_NUMBER" ]; then
  echo "BLOCKED: Could not determine PR number. Include the PR number in the merge command or ensure a PR exists for the current branch." >&2
  exit 2
fi

# Check for verification marker
MARKER="$CWD/.ai-workspace/ship-verified-$PR_NUMBER"
if [ -f "$MARKER" ]; then
  exit 0
fi

echo "BLOCKED: Run /ship first. Self-review must pass before merging PR #$PR_NUMBER." >&2
echo "The enforce-ship hook requires /ship to verify the PR before allowing gh pr merge." >&2
exit 2
