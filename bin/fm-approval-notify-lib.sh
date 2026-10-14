#!/usr/bin/env bash
# fm-approval-notify-lib.sh - opt-in phone/pager notification for a newly held
# captain call.
#
# Sourced by bin/fm-captain-hold.sh after `hold` has durably recorded the call;
# never executed. It adds no daemon, scheduler, or response channel: the
# captain's answer still goes to Firstmate exactly as before, and the
# notification only says that a decision is waiting.
#
# Setup surface: `config/approval-notify` (LOCAL, gitignored, never inherited by
# secondmate homes), one directive per non-empty, non-comment line:
#   off              position-independent kill switch
#   command:<cmd>    run <cmd> through `sh -c`; the message is $1 and on stdin
# This is the same command-channel pattern as config/wedge-alarm, but it is a
# separate file, so the stall alarm keeps its meaning and an absent or empty
# file is inert: nothing is ever sent unless a home lists a command here.
# docs/configuration.md owns the schema and docs/examples/approval-notify is a
# copyable file.
#
# The message is one safe title line (the task title, control characters
# stripped, at most 120 characters) naming the task id, plus a verified pull
# request link when the held task's own metadata, or its `--origin`'s, records
# one that bin/fm-pr-lib.sh accepts. The hold reason, backlog body, command
# strings, and environment are never included, and the command's own output is
# discarded.
#
# Each command runs under bin/fm-timeout-lib.sh's hard bound
# (FM_APPROVAL_NOTIFY_TIMEOUT_SECS, default 10; invalid or zero uses the
# default). One call is identified by the lifecycle identity of its hold
# (the hold-set stamp plus the count of recorded answers), so repeating `hold`
# on a still-open call sends nothing again, answering a call sends nothing, and
# re-holding released or answered work is a new call that notifies again. A
# delivery is recorded in a private marker under
# state/approval-notify/<task-id>.sent only after its command exits 0; the
# marker holds a digest of the command, never the command itself, so a failed
# channel is retried by repeating the same `hold` without repeating a channel
# that already delivered.
#
# Source this file; it defines functions only.

_FM_APPROVAL_NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$_FM_APPROVAL_NOTIFY_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$_FM_APPROVAL_NOTIFY_LIB_DIR/fm-pr-lib.sh"

FM_APPROVAL_NOTIFY_TIMEOUT_SECS_DEFAULT=10
FM_APPROVAL_NOTIFY_TITLE_MAX=120

# Print the configured directives, one per line; nothing when unconfigured.
fm_approval_notify_directives() {  # <config-dir>
  local cfg="$1/approval-notify" line
  [ -f "$cfg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    printf '%s\n' "$line"
  done < "$cfg"
}

# Print the first pull request URL a task's metadata records, only when it is a
# canonical URL; nothing otherwise.
fm_approval_notify_pr_link() {  # <state> <task-id> [<origin-id>]
  local state=$1 owner url
  shift
  for owner in "$@"; do
    [ -n "$owner" ] && [ -f "$state/$owner.meta" ] || continue
    url=$(grep '^pr=' "$state/$owner.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -n "$url" ] && fm_pr_url_parse "$url"; then
      printf '%s\n' "$FM_PR_URL"
      return 0
    fi
  done
  return 0
}

_fm_approval_notify_digest() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# Notify for one newly held captain call. Arguments: the config directory, the
# state directory, the task id, the call's lifecycle identity, the task title,
# and the PR link ("" when none). Returns 0 when nothing needed sending or every
# configured channel has delivered, 1 after printing why any channel did not.
fm_approval_notify() {  # <config-dir> <state> <task-id> <identity> <title> <link>
  local config=$1 state=$2 id=$3 identity=$4 title=$5 link=$6
  local directive cmd timeout digest key marker dir message rc failed=0 off=0
  local -a commands=()
  while IFS= read -r directive; do
    [ -n "$directive" ] || continue
    case "$directive" in
      off) off=1 ;;
      command:*) commands+=("${directive#command:}") ;;
      *)
        printf 'actionable: approval notification for %s was not delivered: unrecognized directive in config/approval-notify (only off and command:<cmd> are supported)\n' "$id" >&2
        failed=1
        ;;
    esac
  done < <(fm_approval_notify_directives "$config")
  [ "$off" -eq 0 ] || return 0
  [ "${#commands[@]}" -gt 0 ] || return "$failed"

  title=$(printf '%s' "$title" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-"$FM_APPROVAL_NOTIFY_TITLE_MAX")
  message="Approval needed: $title [$id]"
  [ -z "$link" ] || message=$(printf '%s\n%s' "$message" "$link")

  timeout=${FM_APPROVAL_NOTIFY_TIMEOUT_SECS:-$FM_APPROVAL_NOTIFY_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$FM_APPROVAL_NOTIFY_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$FM_APPROVAL_NOTIFY_TIMEOUT_SECS_DEFAULT ;;
  esac

  dir="$state/approval-notify"
  marker="$dir/$id.sent"
  for cmd in "${commands[@]}"; do
    [ -n "$cmd" ] || { failed=1; printf 'actionable: approval notification for %s was not delivered: empty command: directive\n' "$id" >&2; continue; }
    digest=$(_fm_approval_notify_digest "$cmd")
    key="$identity $digest"
    if [ -f "$marker" ] && grep -qxF -- "$key" "$marker" 2>/dev/null; then
      continue
    fi
    rc=0
    fm_run_timed "$timeout" sh -c "$cmd" fm-approval-notify "$message" \
      <<< "$message" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      failed=1
      if fm_timed_out "$rc"; then
        printf 'actionable: approval notification for %s was not delivered: the channel timed out after %ss; the captain call is still recorded, repeat the same hold to retry\n' "$id" "$timeout" >&2
      else
        printf 'actionable: approval notification for %s was not delivered: the channel exited %s; the captain call is still recorded, repeat the same hold to retry\n' "$id" "$rc" >&2
      fi
      continue
    fi
    if ! { (umask 077; mkdir -p "$dir") && [ -d "$dir" ] && [ ! -L "$dir" ] \
        && (umask 077; printf '%s\n' "$key" >> "$marker"); }; then
      failed=1
      printf 'actionable: approval notification for %s was delivered but its record could not be written, so a repeated hold may notify again\n' "$id" >&2
    fi
  done
  return "$failed"
}
