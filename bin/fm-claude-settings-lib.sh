#!/usr/bin/env bash
# fm-claude-settings-lib.sh - the ONE owner of how a Claude task worker's
# per-task hooks live in, and leave, its task worktree's
# .claude/settings.local.json.
#
# fm-spawn writes the worker's semantic busy-state and turn-end hooks into that
# file because it is the one Claude settings layer that is per-checkout and
# conventionally uncommitted. Most projects leave it untracked, so the hook
# file is written whole and hidden through the worktree's info/exclude.
# Some projects commit it, which info/exclude cannot hide: an overwritten
# tracked copy reads as an uncommitted change and blocks every tool that
# requires a clean tree, and replacing it would also drop the project's own
# permissions for the worker. For a tracked copy, fm_claude_settings_install
# instead merges the hooks into the project's committed content (read from the
# index, so a relaunch never stacks a second set) and marks the path
# skip-worktree in that task worktree's index only. A linked worktree's index
# is private to it, so the primary checkout and every sibling worktree are
# never touched.
#
# Retirement (relaunch and cleanup) must undo that: a pool reset keeps both the
# skip-worktree bit and a deleted file, so a plain delete would leave the next
# task in that slot silently missing the project's committed settings.
# fm_claude_settings_retire restores the committed copy and clears the bit
# when firstmate's merged copy is in place, leaves a tracked copy without the
# bit alone because that is the worker's own uncommitted edit, and deletes an
# untracked copy exactly as before.
#
# Sourced by bin/fm-spawn.sh and bin/fm-teardown.sh; requires git, and jq for
# the merge. Without jq, or when the committed content cannot be merged safely
# (not a JSON object, a non-object `hooks`, a non-array hook event, or
# `disableAllHooks` set, which would silence the worker hooks), the hook file
# replaces the committed copy, still under skip-worktree, with a warning on
# stderr.

FM_CLAUDE_SETTINGS_REL=.claude/settings.local.json

# fm_claude_settings_tracked <worktree>: succeed when the path is in the
# worktree's index.
fm_claude_settings_tracked() {
  git -C "$1" ls-files --error-unmatch -- "$FM_CLAUDE_SETTINGS_REL" >/dev/null 2>&1
}

# fm_claude_settings_skip_worktree <worktree>: succeed when the path carries
# the skip-worktree bit in the worktree's index.
fm_claude_settings_skip_worktree() {
  local tag
  tag=$(git -C "$1" ls-files -v -- "$FM_CLAUDE_SETTINGS_REL" 2>/dev/null) || return 1
  case "$tag" in
    S\ * | s\ *) return 0 ;;
  esac
  return 1
}

# fm_claude_settings_install <worktree> <hooks-json> <exclude-fn>: write the
# worker's hook settings. <hooks-json> is a JSON object whose `hooks` member
# maps each Claude hook event to its array of matcher groups. <exclude-fn> is
# the caller's function that adds a path to the worktree's info/exclude; it is
# used only for an untracked copy, whose behavior is unchanged.
fm_claude_settings_install() {
  local wt=$1 hooks=$2 exclude_fn=$3 path base merged
  path="$wt/$FM_CLAUDE_SETTINGS_REL"
  mkdir -p "$wt/.claude" || return 1
  if ! fm_claude_settings_tracked "$wt"; then
    printf '%s\n' "$hooks" >"$path" || return 1
    "$exclude_fn" "$FM_CLAUDE_SETTINGS_REL"
    return 0
  fi
  merged=
  if ! command -v jq >/dev/null 2>&1; then
    echo "warning: jq is unavailable, so the tracked $FM_CLAUDE_SETTINGS_REL in $wt is replaced by the worker hooks for this task instead of merged; the project's own settings in that file do not apply to the worker" >&2
  elif ! base=$(git -C "$wt" show ":$FM_CLAUDE_SETTINGS_REL" 2>/dev/null); then
    echo "warning: could not read the committed $FM_CLAUDE_SETTINGS_REL in $wt; it is replaced by the worker hooks for this task" >&2
  elif ! merged=$(printf '%s' "$base" | jq --argjson fm "$hooks" '
      if type != "object" then error("not an object")
      elif (.disableAllHooks // false) != false then error("disableAllHooks is set")
      elif ((.hooks // {}) | type) != "object" then error("hooks is not an object")
      else reduce ($fm.hooks | to_entries[]) as $e (.;
        if ((.hooks[$e.key] // []) | type) != "array" then error("hook event is not an array")
        else .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value) end)
      end' 2>/dev/null); then
    merged=
    echo "warning: the committed $FM_CLAUDE_SETTINGS_REL in $wt cannot be merged safely (not a JSON object, malformed hooks, or disableAllHooks set); it is replaced by the worker hooks for this task" >&2
  fi
  if [ -n "$merged" ]; then
    printf '%s\n' "$merged" >"$path" || return 1
  else
    printf '%s\n' "$hooks" >"$path" || return 1
  fi
  git -C "$wt" update-index --skip-worktree -- "$FM_CLAUDE_SETTINGS_REL"
}

# fm_claude_settings_retire <worktree>: remove the worker's hook settings from
# the worktree, restoring a tracked copy instead of deleting it.
fm_claude_settings_retire() {
  local wt=$1
  [ -n "$wt" ] || return 1
  if fm_claude_settings_tracked "$wt"; then
    fm_claude_settings_skip_worktree "$wt" || return 0
    git -C "$wt" update-index --no-skip-worktree -- "$FM_CLAUDE_SETTINGS_REL" &&
      git -C "$wt" checkout -q -- "$FM_CLAUDE_SETTINGS_REL"
    return
  fi
  rm -f -- "$wt/$FM_CLAUDE_SETTINGS_REL"
}
