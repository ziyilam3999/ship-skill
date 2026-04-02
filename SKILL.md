---
name: ship
description: >
  Full git shipping pipeline: commit, branch, push, create PR, wait for CI,
  self-review loop (with bug fix iterations), and merge. Use when the user says
  "/ship", "ship it", "ship this", "commit and merge", "push and merge",
  "create PR and merge", or wants to go from working changes to a merged PR
  in one command. Do NOT use for simple git operations like just committing
  or just pushing -- this is the full end-to-end pipeline.
---

# Ship Pipeline

Execute the full git shipping pipeline on the current working directory. If `$ARGUMENTS` is provided, use it as a hint for the commit message.

## Pipeline Overview

| Stage | Name | Action | Abort condition |
|-------|------|--------|-----------------|
| 0 | Pre-flight | Check for changes, branch, gh auth | Nothing to commit |
| 1 | Branch | Create feature branch if on master | -- |
| 2 | Commit | Stage files and commit | -- |
| 3 | Push + PR | Push and create PR via gh | -- |
| 4 | CI Wait | Poll `gh pr checks` up to 10 min | CI failure |
| 5 | Self-review | Stateless reviewer loop (max 5) | 5 iterations exhausted |
| 6 | Merge | Squash merge via gh | Merge conflict |
| 7 | Release | Version bump, changelog, tag, GitHub Release | -- |
| 8 | Cleanup | Switch to master, pull, delete branch | -- |

Print a status line before each stage:
```
[SHIP {N}/8] {description}...
```

---

## Stage 0 -- PRE-FLIGHT

Run these checks. Abort with a clear message if any fail.

```bash
git status --porcelain        # empty = nothing to ship
git branch --show-current     # detect master vs feature branch
gh auth status                # verify gh is authenticated
```

- If `git status --porcelain` is empty, print "Nothing to ship." and stop (still record this as an aborted run — see Run Data Recording).
- Store the current branch name for later decisions.
- Capture `run_start_time` as the current ISO-8601 timestamp. Initialize an in-memory run record to accumulate metrics throughout the pipeline.

## Stage 1 -- BRANCH

**On master/main:** Analyze the diff to derive a branch name with a conventional prefix:
- `feat/` for new features
- `fix/` for bug fixes
- `chore/` for maintenance, config, docs

Create the branch: `git checkout -b {prefix}/{slug}`

**On feature branch:** Skip. Log "Already on branch {name}".

## Stage 2 -- COMMIT

1. Stage relevant files with `git add` (list specific files, never use `-A` or `.`)
2. Craft a conventional commit message from the diff. If `$ARGUMENTS` is provided, use it as a hint.
3. Commit using a HEREDOC for the message, including `Co-Authored-By` trailer.

## Stage 3 -- PUSH + PR

1. `git push -u origin {branch}`
2. Check if a PR already exists:
   ```bash
   gh pr view --json number,url 2>/dev/null
   ```
   - **Exists:** Log the URL, skip creation.
   - **Does not exist:** Create via `gh pr create --title "..." --body "..."` with a summary and test plan.
3. Store the PR number for subsequent stages.

## Stage 4 -- CI WAIT

Poll CI checks every 30 seconds, up to 10 minutes:

```bash
gh pr checks {pr-number}
```

- **All pass:** Record `ciOutcome: "pass"`. Proceed to Stage 5.
- **Any fail:**
  1. Parse failing check names from `gh pr checks` output.
  2. **If any failing check name contains `code-review`** (case-insensitive) AND this is the **first** retry attempt:
     a. Print: `"Code-review CI failed — checking OAuth token freshness..."`
     b. Read `$USERPROFILE/.claude/.credentials.json`, extract `claudeAiOauth.expiresAt` (unix ms).
     c. If token is **expired or expiring within 30 minutes**:
        - Run `bash $USERPROFILE/coding_projects/ai-brain/tools/sync-oauth-token.sh`
        - If sync succeeds: re-trigger with `gh run rerun --failed -R {owner/repo}` on the failing run, record `ciOauthSynced: true` and `ciRetried: true`, reset CI poll timer, **resume polling** (fresh 10-min timeout).
        - If sync fails: report the sync error and abort.
     d. If token is **fresh** (>30 min remaining): not a token issue — abort as normal.
  3. **Otherwise** (non-code-review failure, or second attempt after retry): Record `ciOutcome: "fail"`. Report failing check names and log URLs. **Abort** — do not auto-fix CI config issues.
- **No checks configured** (empty output): Record `ciOutcome: "none"`. Skip, proceed to Stage 5.
- **Timeout (10 min):** Record `ciOutcome: "timeout"`. Report current status and ask the user whether to continue or abort.

Record `ciWaitSeconds` as the elapsed time from the first poll to resolution.

## Stage 5 -- SELF-REVIEW LOOP

Iterate up to **5 times**. Each iteration:

### 5a. Spawn Stateless Reviewer

Launch a fresh Agent subagent using the full prompt in `references/reviewer-prompt.md` (relative to this skill's base directory, NOT the current working directory). The reviewer must have NO context about the implementation -- fresh eyes only.

### 5b. Process the Review

Read `tmp/ship-review-{N}.md` and act on the verdict:

**PASS (no bugs):**
- Write verification marker: `echo "{ISO-8601 timestamp}" > .ai-workspace/ship-verified-{pr-number}` (in the project's `.ai-workspace/` dir). This marker allows the enforce-ship hook to permit the merge in Stage 6.
- For each enhancement found, auto-create a GitHub issue:
  ```bash
  gh issue create --title "{summary}" --body "{description}" --label "enhancement" --label "ship-review"
  ```
- Log created issue URLs. Record `enhancementsCreated` (count of issues created). Proceed to Stage 6.

**BLOCK (bugs found):**
1. For each bug found, append to the run record's `issues` array: `{ "stage": "selfReview", "type": "{bug_type}", "description": "{bug_summary}", "iteration": {N} }`.
2. Increment `bugsFound` counter. Add each bug's type to `bugCategories` (deduplicated).
3. Create a micro-plan at `.ai-workspace/plans/{date}-ship-fix-{N}.md` (satisfies the enforce-plan hook).
4. Fix all reported bugs.
5. `git add` the fixed files. Create a **new commit** (not amend). `git push`.
6. Re-poll CI checks (Stage 4 mini-loop).
7. Increment iteration counter (`reviewIterations`).
   - If counter >= 5: print remaining bugs and escalate to user. **Do NOT merge.**
   - Otherwise: re-enter Stage 5 (next iteration).

## Stage 6 -- MERGE

```bash
gh pr merge {pr-number} --squash --delete-branch
```

If merge fails due to conflicts, report the conflicting files and **abort**. Do not auto-resolve.

## Stage 7 -- RELEASE

Inline version bump, changelog, tag, and GitHub Release. No external automation PRs.

1. **Check if repo is releasable:** Look for `package.json` at the repo root.
   - If not found: log "No package.json — skipping release." Proceed to Stage 8.

2. **Get last tag:**
   ```bash
   git checkout master && git pull
   git describe --tags --abbrev=0 2>/dev/null
   ```
   - If no tags exist: use `0.0.0` as baseline, default bump = minor (→ `0.1.0`).

3. **Collect commits since last tag:**
   ```bash
   git log {last_tag}..HEAD --format="%s"
   ```

4. **Determine version bump** from conventional commit prefixes:
   - Any commit with `!` suffix (e.g., `feat!:`) or `BREAKING CHANGE` in body → **major**
   - Any `feat` or `feat(scope)` prefix → **minor**
   - Only `fix`, `chore`, `docs`, `refactor`, `test`, `style`, `perf`, `ci`, `build` → **patch**
   - No conventional commits found → **patch** (default)

5. **Compute new version:** Increment the appropriate semver component of the last tag.

6. **Update package.json:** Set `"version": "{new_version}"` using a targeted edit.

7. **Generate CHANGELOG entry:**
   - Group commits by type: `### Features` (feat), `### Bug Fixes` (fix), `### Miscellaneous` (everything else)
   - Format: `## [{version}](https://github.com/{owner/repo}/compare/{last_tag}...v{version}) ({date})`
   - Prepend to `CHANGELOG.md` (create the file if missing).

8. **Commit + tag + push:**
   ```bash
   git add package.json CHANGELOG.md
   git commit -m "chore: release {version}"
   git tag v{version}
   git push && git push --tags
   ```

9. **Create GitHub Release:**
   ```bash
   gh release create v{version} --title "v{version}" --notes "{changelog_entry}"
   ```

10. Log: `[SHIP] Released v{version} — tag, changelog, and GitHub Release created.`
11. Record `releaseVersion: "{version}"` and `releaseBump: "major|minor|patch"` in the run record. If release was skipped (no package.json), record `releaseVersion: null` and `releaseBump: "skipped"`.

**Important:** This stage is non-fatal. The feature PR is already merged. Any failure here should log a warning and continue to Stage 8, never abort.

## Stage 8 -- CLEANUP

```bash
git checkout master && git pull
git branch -d {branch} 2>/dev/null   # delete local if still exists
rm -f .ai-workspace/ship-verified-{pr-number}   # clean up verification marker
```

**Persist run data** (see Run Data Recording section below), then print a final summary:
- PR URL and merge commit SHA
- Number of review iterations performed
- GitHub issues created (if any)
- Release version (if Stage 7 created a tag)

---

## Run Data Recording (always runs)

This section executes regardless of whether stages succeeded or failed. If the pipeline aborts at any stage, still record the run before stopping.

### What to record

Build the run record from metrics accumulated throughout the pipeline:

```json
{
  "timestamp": "{run_start_time}",
  "durationSeconds": "{now - run_start_time in seconds}",
  "outcome": "success|partial|failure|aborted",
  "project": "{current project directory name}",
  "trigger": "/ship {$ARGUMENTS or empty}",
  "stages": {
    "preflight": "pass|fail|skip",
    "branch": "pass|fail|skip",
    "commit": "pass|fail|skip",
    "pushPr": "pass|fail|skip",
    "ciWait": "pass|fail|skip",
    "selfReview": "pass|fail|skip",
    "merge": "pass|fail|skip",
    "release": "pass|fail|skip",
    "cleanup": "pass|fail|skip"
  },
  "metrics": {
    "prUrl": "{PR URL or null}",
    "prNumber": "{PR number or null}",
    "branchName": "{branch name}",
    "reviewIterations": "{count, 0 if not reached}",
    "bugsFound": "{total bugs across all iterations}",
    "bugCategories": ["{deduplicated list of bug types}"],
    "enhancementsCreated": "{count of GH issues created}",
    "ciWaitSeconds": "{seconds spent polling CI}",
    "ciOutcome": "pass|fail|timeout|none|null",
    "ciOauthSynced": "{true if token was synced during CI wait, omit otherwise}",
    "ciRetried": "{true if CI was re-triggered after token sync, omit otherwise}",
    "ciRetryOutcome": "pass|fail|timeout|null",
    "releaseVersion": "{version or null}",
    "releaseBump": "major|minor|patch|skipped|null",
    "commitCount": "{number of commits: initial + fix iterations}"
  },
  "issues": [
    { "stage": "{stage}", "type": "{issue_type}", "description": "{description}" }
  ],
  "summary": "{one-line description of what happened}"
}
```

**Outcome values:**
- `success` — merged and released (or merged + release skipped because no package.json)
- `partial` — merged but release failed
- `failure` — merge failed (conflicts, branch protection)
- `aborted` — pipeline stopped early (nothing to ship, CI failure, auth failure, 5 iterations exhausted, network error)

For aborted runs, also set:
- `metrics.abortStage`: the stage name where the pipeline stopped
- `metrics.abortReason`: one-line explanation

### Where to write

All paths are relative to this skill's base directory (resolved from the symlink, i.e., `ai-brain/skills/ship/`):

1. **`runs/data.json`** — Read the existing file (create if missing with `{"skill":"ship","lastRun":null,"totalRuns":0,"runs":[]}`). Append the new run record to the `runs` array. If `runs.length > 20`, remove the oldest entries to keep exactly 20. Increment `totalRuns` by 1. Set `lastRun` to the run's timestamp. Write the file.

2. **`runs/run.log`** — Append one line: `{timestamp} | {outcome} | {durationSeconds}s | {summary}`. If the log exceeds 100 lines, trim the oldest lines to keep exactly 100.

### Important

- **Always record**, even on abort. A "nothing to ship" abort is still a run worth tracking (it reveals invocation patterns).
- **Do not fail the pipeline** if recording fails (e.g., file permission error). Log a warning and continue.
- **Resolve the skill base directory** from the symlink target, not the current working directory. The runs/ folder lives alongside SKILL.md.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| No changes to commit | Abort: "Nothing to ship." |
| Already on feature branch | Skip branch creation |
| PR already exists for branch | Skip PR creation, use existing |
| CI fails | Report check names + URLs, abort |
| Merge conflicts | Report conflicting files, abort |
| 5 review iterations exhausted | List remaining bugs, escalate to user |
| No CI checks configured | Skip CI wait, proceed to review |
| `gh` auth failure | Report error, abort |
| Network error during any `gh` call | Report the error, abort cleanly |
| No package.json in repo | Skip Stage 7 entirely |
| No git tags exist | Use 0.0.0 baseline, bump to 0.1.0 |
| No conventional commits since last tag | Default to patch bump |
| Tag/push fails | Log warning, skip — feature is already merged |
| GitHub Release creation fails | Log warning, skip — tag still exists |
