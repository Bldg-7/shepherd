# Workspace hygiene

- After each completed work batch, remove unneeded artifacts, retired staged apps,
  test executables/caches, and temporary worktrees created for that batch. Cleanup
  is part of completion, not an optional final step.
- Check for active builds/processes and confirm owned resource retirement first.
  Never stop a user program, delete an in-use executable/cache, or use `--force`
  to remove a worktree with uncommitted/untracked work.
- Preserve source, unrelated dirty/untracked files, branches/unmerged commits,
  provenance, logs, validation receipts, screenshots/geometry and artifacts still
  needed for the next gate. Prefer normal `git worktree remove` for a known-owned,
  clean, no-longer-needed worktree. Do not remove pre-existing worktrees merely
  because their commits are merged; activity/ownership must be established.
- Use exact known owned output roots and record cleanup results. Do not recursively
  search `/tmp`, `/private/tmp`, user homes or protected folders to discover trash.
  Never change privacy grants or global tools/settings for cleanup.
