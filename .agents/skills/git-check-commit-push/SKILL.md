---
name: git-check-commit-push
description: Check for untracked/modified changes in the workspace, draft a descriptive commit message, commit them, and push the commit.
---

# Git Check, Commit, and Push

This skill automates checking for local modifications/untracked files, staging them, committing them with a descriptive message, and pushing to the remote repository.

## Triggering

Trigger this skill when the user asks to "check for changes and commit/push", "sync repo", "push my changes", or similar requests.

## Workflow

1. **Check for changes**:
   - Run `git status` in the repository's root directory.
   - If there are no changes, inform the user that the workspace is clean.

2. **Stage files**:
   - Run `git add -A` (or a specific path if requested) to stage all changes.

3. **Formulate a descriptive commit message**:
   - Look at the modified/added files from `git status` or run `git diff --cached --stat` to see what changed.
   - Write a detailed, conventional commit message based on the actual edits (e.g. `docs: update help files`, `feat: add helper function`, `fix: loader issue`).

4. **Commit changes**:
   - Run `git commit -m "<message>"` with the formulated message.

5. **Push to remote**:
   - Run `git push` to push the commits to the upstream branch.
