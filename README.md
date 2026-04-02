# /ship -- Claude Code Shipping Pipeline

A Claude Code skill that takes you from working changes to a merged PR in one command. Commits, creates a PR, waits for CI, runs a stateless self-review that auto-fixes bugs (up to 5 iterations), merges, and optionally creates a versioned release.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and logged in
- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated

## Install

```bash
git clone https://github.com/ziyilam3999/ship-skill.git
bash ship-skill/scripts/setup-ship.sh
```

The setup script:
1. Symlinks the skill to `~/.claude/skills/ship/`
2. Installs the `enforce-ship` hook to `~/.claude/hooks/`
3. Registers the hook in `~/.claude/settings.json`

## Usage

```
/ship                    # Ship current changes
/ship fix the login bug  # Ship with a commit message hint
```

## What it does

| Stage | Action |
|-------|--------|
| 0. Pre-flight | Check for changes, verify `gh` auth |
| 1. Branch | Create `feat/`, `fix/`, or `chore/` branch |
| 2. Commit | Stage files, craft conventional commit |
| 3. Push + PR | Push branch, create PR |
| 4. CI Wait | Poll CI checks up to 10 min |
| 5. Self-review | Stateless reviewer finds bugs, auto-fixes them |
| 6. Merge | Squash merge via `gh` |
| 7. Release | Version bump, changelog, tag, GitHub Release |
| 8. Cleanup | Switch to master, delete branch |

## Enforce-ship hook

The included `enforce-ship` hook blocks any `gh pr merge` command unless `/ship` has reviewed the PR. This prevents agents from merging unreviewed code. The hook:

- Fires on every `Bash` tool call (fast-path exits for non-merge commands)
- Checks for a verification marker written by `/ship` after self-review passes
- Blocks with a clear message if the marker is missing

## Update

```bash
cd ship-skill && git pull
```

Symlinks mean changes take effect immediately.

## License

MIT
