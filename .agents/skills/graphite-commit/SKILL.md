---
name: graphite-commit
description: Work with Graphite (`gt`) stacked PRs - creating, navigating, and managing PR stacks - using conventional commit messages. Use in Graphite or stacked-PR environments when the user asks to create or amend commits, run `/commit`, stage changes, stack changes, generate Conventional Commit messages, create Graphite branches, submit stacked PRs, navigate stacks, repair stack parentage, restack, or troubleshoot Graphite workflows.
license: MIT
allowed-tools:
  - "Bash(gt *)"
  - "Bash(git add *)"
  - "Bash(git reset *)"
  - "Bash(git diff *)"
  - "Bash(git status *)"
  - "Bash(git stash *)"
  - "Bash(git checkout *)"
  - "Bash(git rebase *)"
  - "Bash(git branch *)"
  - "Bash(gh pr *)"
---

# Graphite Stacked PRs with Conventional Commits

Use this skill to turn local changes into well-scoped conventional commits inside Graphite stacked pull requests. In a Graphite or stacked-PR workflow, it replaces a generic git commit workflow by combining diff analysis, staging, commit message generation, Graphite branch creation, stack updates, PR submission, and recovery guidance.

## Safety Rules

- Inspect the worktree before changing git state: `git status --short`.
- Preserve user changes. Do not revert, discard, or overwrite changes you did not make unless the user explicitly asks.
- Never commit secrets such as `.env`, credentials, tokens, private keys, or generated private config.
- Never update git config unless the user explicitly asks.
- Never skip hooks with `--no-verify` unless the user explicitly asks.
- Never force push to `main`, `master`, or trunk.
- Treat `git reset`, `git rebase`, `gt delete -f`, and force pushes as destructive or high-risk. Use them only when they are necessary and the user intent is clear.
- If hooks fail, fix the issue and update the Graphite branch with `gt modify`; do not bypass hooks.

## Quick Reference

| I want to...                       | Command                                                                        |
| ---------------------------------- | ------------------------------------------------------------------------------ |
| Inspect changed files              | `git status --short`                                                           |
| Inspect staged changes             | `git diff --staged`                                                            |
| Inspect unstaged changes           | `git diff`                                                                     |
| Stage specific files               | `git add <files>`                                                              |
| Interactively stage hunks          | `git add -p`                                                                   |
| Create a stacked branch            | `gt create <branch-name> -m "<message>" --no-ai --no-interactive`              |
| Amend current branch               | `gt modify -m "<message>" --no-interactive`                                    |
| Add a new commit to current branch | `gt modify --commit -m "<message>" --no-interactive`                           |
| View stack structure               | `gt ls`                                                                        |
| Move up the stack                  | `gt up`                                                                        |
| Move down the stack                | `gt down`                                                                      |
| Jump to top of stack               | `gt top`                                                                       |
| Jump to bottom of stack            | `gt bottom`                                                                    |
| Rebase stack                       | `gt restack`                                                                   |
| Track or re-parent a branch        | `gt track --parent <branch>`                                                   |
| Submit the full stack              | `gt submit --stack --no-edit --no-interactive`                                 |
| Merge current PR when ready        | `gt submit --no-stack --publish --merge-when-ready --no-edit --no-interactive` |
| Merge full stack when ready        | `gt submit --stack --publish --merge-when-ready --no-edit --no-interactive`    |
| Edit a PR body                     | `gh pr edit <PR_NUMBER> --body-file /tmp/pr-body.md`                           |

## Commit Analysis Workflow

### What Makes A Good Graphite PR

Evaluate candidate PRs in roughly this order:

- **Atomic/hermetic**: independent of unrelated changes, able to pass CI, and safe to deploy on its own.
- **Narrow semantic scope**: limited to one module, feature, behavior, or the same mechanical change across related modules.
- **Small diff**: compact enough to review without hiding the intent.

Do NOT worry about creating too many PRs. It is **always** preferable to create more PRs than fewer. **NO CHANGE IS TOO SMALL**: tiny PRs give larger-scoped PRs more clarity. Always argue in favor of creating more PRs, as long as each can pass validation independently.

### 1. Inspect State

Run `git status --short`, `git diff --staged`, and `git diff`. Use staged changes when they exist. If nothing is staged, inspect the working tree and decide which logical group should become the next commit or PR.

### 2. Group Changes

Prefer one logical change per commit and one independently valid change per PR. Smaller PRs are usually better when each PR can pass validation and make sense on its own.

Good grouping signals:

- Same feature, bug, module, or behavior.
- A test change paired with the implementation it validates.
- A repository-wide mechanical change that is clearly one operation.
- A documentation update that explains the paired code change.

Split changes when unrelated features, bug fixes, refactors, or generated artifacts are mixed together. Do not split so aggressively that a PR cannot build, test, or be reviewed independently.

### 3. Stage Intentionally

Stage only the files or hunks for the current logical change:

```bash
git add path/to/file1 path/to/file2
git add -p
```

After staging, run `git diff --staged` to verify exactly what will be committed.

### 4. Generate The Message

Analyze the staged diff and choose:

- **Type**: the kind of change.
- **Scope**: the smallest useful area, module, package, feature, or subsystem; optional but encouraged.
- **Description**: imperative, present tense, under 72 characters when practical.
- **Body**: prefer one even for small changes; keep it brief when context is simple.
- **Footer**: issue references or breaking-change metadata.

Examples:

```text
feat(auth): add session refresh warning
fix(api): handle empty pagination cursors
refactor(ui): simplify toolbar state handling
test(parser): cover nested block parsing
docs: update Graphite workflow guidance
```

## Conventional Commit Format

Use Conventional Commits:

```text
<type>(<scope>): <description>

<optional body>

<optional footer>
```

The scope is optional but encouraged when it adds useful routing or review context:

```text
docs: update release checklist
```

### Types

| Type       | Purpose                                              |
| ---------- | ---------------------------------------------------- |
| `feat`     | New feature                                          |
| `fix`      | Bug fix                                              |
| `docs`     | Documentation-only change                            |
| `style`    | Formatting or style-only change with no logic impact |
| `refactor` | Code change that is neither a feature nor a bug fix  |
| `perf`     | Performance improvement                              |
| `test`     | Add or update tests                                  |
| `build`    | Build system, package manager, or dependency change  |
| `ci`       | CI or automation change                              |
| `chore`    | Maintenance that does not fit another type           |
| `revert`   | Revert a previous change                             |

### Message Rules

- Use imperative mood: `add`, not `adds` or `added`.
- Keep the description specific and compact.
- Do not end the description with a period.
- Prefer a body even for small changes; briefly record rationale, tradeoffs, migrations, validation, behavior changes, or why it belongs in this branch/PR.
- Reference issues in the footer when relevant: `Closes #123`, `Refs #456`.

### Breaking Changes

Use `!` after the type or scope:

```text
feat(api)!: remove deprecated session endpoint
```

Or add a footer:

```text
feat(config): allow nested project configs

BREAKING CHANGE: project config resolution now stops at workspace root
```

## Graphite Stack Workflow

### Branch Naming

Use a shared stack prefix and a terse change description:

```text
<stack-topic>/<change-description>
```

Example:

```text
auth-bugfix/reorder-args
auth-bugfix/improve-logging
auth-bugfix/update-docs
auth-bugfix/handle-401-status
```

### Create A New Stack

1. Inspect and stage the first logical change.
2. Create the first branch with a Conventional Commit message.
3. Repeat for each upstack PR.
4. Validate each branch when practical.
5. Submit the stack.

```bash
gt create auth-bugfix/reorder-args -m "fix(auth): reorder login arguments" --no-ai --no-interactive
```

For a commit with a body, pass multiple message arguments:

```bash
gt create auth-bugfix/improve-logging \
  -m "fix(auth): add login failure logging" \
  -m "Record provider and status details so support can diagnose failed login attempts." \
  --no-ai \
  --no-interactive
```

**`-m` values must not start with `-` (hyphen).** Yargs — the parser gt uses — treats a value beginning with `-` as bundled short flags, producing spurious "Unknown arguments" errors. Use `*` for bullets in message bodies instead of `-`:

```bash
gt create auth-bugfix/add-retry \
  -m "fix(auth): retry login on 429" \
  -m "* Exponential backoff from 1 s to 30 s." \
  -m "* Coalesces concurrent retry payloads before re-enqueue." \
  --no-ai \
  --no-interactive
```

### Handle Untracked Branches

Before creating branches from a worktree or local branch, check whether Graphite tracks it:

```bash
gt branch info
```

If Graphite reports that the branch is untracked, track it against trunk before creating the stack:

```bash
gt track --parent main
```

Preferred recovery is to track temporarily, create the stack normally, then re-parent the first new branch onto trunk:

```bash
gt checkout <first-branch>
gt track --parent main
gt restack
```

Use the repository's configured trunk if it is not `main`.

If tracking the current branch is not appropriate, stash local changes and restart from trunk:

```bash
git stash
git checkout main
git pull
git checkout -b temp-working
git stash pop
gt track --parent main
gt create <branch-name> -m "<message>" --no-ai --no-interactive
```

Use this fallback only when the stash/pull workflow is safe for the current repo and user request.

### Navigate A Stack

```bash
gt ls
gt up
gt down
gt top
gt bottom
```

Use `gt ls` before stack operations so the current branch and parentage are clear.

## Updating Existing Branches

### Amend Current Branch

Use this when the staged changes belong in the existing branch commit:

```bash
git add <files>
git diff --staged
gt modify -m "fix(auth): handle empty login redirect" --no-interactive
```

If the branch has an open PR and the change meaningfully alters what that PR does, update the PR body with `gh pr edit`.

### Add A Commit To Current Branch

Use this when the branch should contain another commit instead of amending the previous one:

```bash
git add <files>
git diff --staged
gt modify --commit -m "test(auth): cover empty login redirect" --no-interactive
```

If the branch has an open PR and the new commit meaningfully changes the scope of that PR, update the PR body with `gh pr edit`.

### Reorder Or Re-parent

Use `gt move` to reorder stack branches. This is usually simpler than trying to use `gt create --insert`.

Use `gt track --parent <branch>` when a branch has the wrong parent, then run `gt restack`.

```bash
gt checkout <branch>
gt track --parent <new-parent>
gt restack
```

### Rename A Branch

```bash
gt rename <new-branch-name>
```

## Resetting Commits to Unstaged Changes

When committed work needs to be re-stacked differently, and after confirming the commits are local or safe to rewrite:

```bash
git status --short
git log --oneline --decorate -5
git reset HEAD^       # reset last commit, keep changes unstaged
git reset HEAD~2      # reset multiple commits
git diff HEAD         # inspect what you're working with
```

Then stage the first logical group and create or modify Graphite branches from that staged subset.

## Submitting And Editing PRs

### Validate First

Before submitting, run the repository's validation commands from project instructions such as `AGENTS.md`, package scripts, Makefiles, or repository docs.

Common validation categories:

- Formatting or linting.
- Type checks.
- Unit tests for touched areas.
- Build checks when user-facing or shared code changed.

If validation fails, fix the issue, stage the fix, and use `gt modify`.

### Submit The Stack

Check the stack and verify the first PR is rooted on trunk before submitting:

```bash
gt ls
```

If the first branch has the wrong parent, fix parentage before submitting:

```bash
gt checkout <first-branch>
gt track --parent main
gt restack
```

Use the repository's configured trunk if it is not `main`, then submit:

```bash
gt submit --stack --no-edit --no-interactive
```

Use `--dry-run` when unsure what Graphite will submit, stack shape is ambiguous, or confirmation is required:

```bash
gt submit --stack --dry-run --no-edit --no-interactive
```

After submitting, edit PR descriptions for non-trivial PRs — see **PR Descriptions** below.

### PR Titles

Use the commit title as the PR title unless the repository has a different convention. Keep titles terse and specific:

```text
fix(auth): handle empty login redirect
```

### PR Descriptions

Create a temporary markdown file for the PR body, then pass it with `--body-file`:

```bash
gh pr edit <PR_NUMBER> --title "fix(auth): handle empty login redirect" --body-file /tmp/pr-body.md
```

Avoid shell heredocs for PR descriptions because Markdown tables, code fences, and shell interpolation are easy to break.

#### First PR (trunk-facing)

The trunk-facing PR owns the stack description. Identify it with `gt bottom && gt branch info` (or non-mutating: `gt log --stack --reverse`, then `gt branch info <first-branch-above-trunk>`). Do not infer it from the current work segment. Write this description when the first PR is created; update it before using --merge-when-ready or merging. Graphite auto-comments individual PR links, so no need to list them manually.

```markdown
## Stack

This stack fixes login redirect handling and improves diagnostics around failed auth flows.

## What?

Handle empty redirect parameters before building the callback URL.

## Why?

Users can currently hit a blank redirect path after provider login. This branch keeps the callback valid and sets up the logging changes upstack.
```

#### Middle and top PRs

Subsequent PRs describe only their own change. Graphite auto-comments the stack links.

```markdown
## What?

Add login failure logging with provider and status details.

## Why?

Support needs structured context to diagnose failed login attempts.
```

#### Updating the stack description

Before using --merge-when-ready or merging, revisit the first PR's description and update it to reflect the final scope — any PRs dropped, added, or significantly changed since creation.

## Troubleshooting And Recovery

| Problem                               | Action                                                                           |
| ------------------------------------- | -------------------------------------------------------------------------------- |
| Untracked branch                      | Run `gt track --parent <trunk>`                                                  |
| Stack parented on wrong branch        | Checkout the first branch, run `gt track --parent <trunk>`, then `gt restack`    |
| Need to reorder PRs                   | Run `gt move`                                                                    |
| Need to rename current branch         | Run `gt rename <new-name>`                                                       |
| Conflicts during restack              | Resolve conflicts, stage files, then `git rebase --continue`                     |
| Need to split a PR                    | Reset only local/safe commits, stage selectively, then create or modify branches |
| Need to delete a branch               | Use `gt delete <branch> -f -q` only when deletion is explicitly intended         |
| `gt restack` hits unrelated conflicts | Use a targeted `git rebase <target>` for the affected branch                     |

### Targeted Rebase

In deeply nested stacks with many sibling branches, `gt restack` can restack every branch that needs it, hit conflicts in unrelated branches, and become hard to apply surgically.

Use direct git rebase only when:

- You only want to update specific branches in your stack.
- `gt restack` is hitting conflicts in unrelated branches.
- You need to skip obsolete commits during the rebase.

```bash
git checkout <branch>
git rebase <target-branch>
```

On conflict: stage resolved files with `git add` and run `git rebase --continue`. To skip an obsolete commit: `git rebase --skip`.

After the rebase, verify state and repair if needed:

```bash
gt ls
gt track --parent <target-branch>  # if parent metadata is wrong
gt restack                          # if descendants need rebasing
```

### Interrupted Rebase

When resuming after an interrupted rebase:

1. Run `git status` and look for `interactive rebase in progress` or `Unmerged paths`.
2. Inspect unmerged files.
3. If files are already resolved and have no conflict markers, stage them.
4. Continue with `git rebase --continue`.
5. Run `gt ls` after completion to verify stack shape.

### Delete Branches

Only delete branches when that is the requested outcome.

```bash
gt delete <branch> -f -q
gt delete <branch> -f -q --upstack
gt delete <branch> -f -q --downstack
```

(`-f`: force-deletes unmerged/unclosed branches; `-q`: quiet, no prompts.)

After deleting an intermediate branch, Graphite normally restacks children onto the parent. If tracking still looks wrong:

```bash
gt checkout <child-branch>
gt track --parent <new-parent>
gt restack
```
