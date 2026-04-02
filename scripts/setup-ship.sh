#!/bin/bash
# Setup script for the /ship skill
# Installs the skill + enforce-ship hook in one command
#
# Usage: bash setup-ship.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SKILLS_DIR="${CLAUDE_DIR}/skills"
HOOKS_DIR="${CLAUDE_DIR}/hooks"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"


# Pre-flight: check dependencies
for cmd in git gh node; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[setup] ERROR: '$cmd' is required but not installed." >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "[setup] ERROR: gh is not authenticated. Run 'gh auth login' first." >&2; exit 1; }

echo "[setup] Installing /ship skill..."

# Create directories if needed
mkdir -p "$SKILLS_DIR"
mkdir -p "$HOOKS_DIR"

# 1. Symlink skill folder
if [ -L "$SKILLS_DIR/ship" ]; then
  echo "[setup] Skill symlink already exists, updating..."
  rm "$SKILLS_DIR/ship"
fi
if [ -d "$SKILLS_DIR/ship" ]; then
  echo "[setup] WARNING: $SKILLS_DIR/ship is a directory, not a symlink. Skipping skill install."
  echo "[setup] Remove it manually if you want to reinstall."
else
  ln -s "$SKILL_DIR" "$SKILLS_DIR/ship"
  echo "[setup] Skill symlinked: $SKILLS_DIR/ship -> $SKILL_DIR"
fi

# 2. Symlink enforce-ship hook
HOOK_SRC="$SKILL_DIR/hooks/enforce-ship.sh"
HOOK_DST="$HOOKS_DIR/enforce-ship.sh"
if [ -f "$HOOK_SRC" ]; then
  ln -sf "$HOOK_SRC" "$HOOK_DST"
  echo "[setup] Hook symlinked: $HOOK_DST -> $HOOK_SRC"
else
  echo "[setup] WARNING: enforce-ship.sh not found at $HOOK_SRC. Hook not installed."
fi

# 3. Register hook in settings.json
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Check if enforce-ship hook is already registered
if grep -q "enforce-ship.sh" "$SETTINGS_FILE" 2>/dev/null; then
  echo "[setup] Hook already registered in settings.json"
else
  # Add hook registration using node
  SETTINGS_FILE="$SETTINGS_FILE" node -e '
const fs = require("fs");
const settingsFile = process.env.SETTINGS_FILE;
const settings = JSON.parse(fs.readFileSync(settingsFile, "utf8"));
if (!settings.hooks) settings.hooks = {};
if (!settings.hooks.PreToolUse) settings.hooks.PreToolUse = [];
settings.hooks.PreToolUse.push({
  matcher: "Bash",
  hooks: [{
    type: "command",
    command: "bash ~/.claude/hooks/enforce-ship.sh",
    timeout: 10
  }]
});
fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2));
'
  echo "[setup] Hook registered in settings.json"
fi

# 4. Create runs directory for run data recording
RUNS_DIR="$SKILL_DIR/runs"
if [ ! -d "$RUNS_DIR" ]; then
  mkdir -p "$RUNS_DIR"
  echo '{"skill":"ship","lastRun":null,"totalRuns":0,"runs":[]}' > "$RUNS_DIR/data.json"
  touch "$RUNS_DIR/run.log"
  echo "[setup] Created runs/ directory for run data recording"
fi

echo ""
echo "[setup] Done! /ship is now installed."
echo ""
echo "Usage:"
echo "  /ship              Ship current changes (commit, PR, review, merge)"
echo "  /ship fix the bug  Ship with a commit message hint"
echo ""
echo "The enforce-ship hook blocks 'gh pr merge' unless /ship has reviewed the PR."
echo "To update: cd $SKILL_DIR && git pull (symlinks update automatically)"
