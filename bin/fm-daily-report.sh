#!/usr/bin/env bash
# Schedule a daily report wake; never compose mail, read credentials, or send it.
# Usage (FM_HOME must name an absolute home):
#   fm-daily-report.sh arm|disarm|check
#   fm-daily-report.sh status|claim|sent|retry YYYY-MM-DD
#   fm-daily-report.sh --help
# Read config/daily-report (schema: docs/configuration.md "Daily report").
# arm registers state/daily-report.check.sh via fm-check-register.sh; disarm
# unregisters it without deleting history. Re-arm after moving the code root.
# state/.daily-report/start is the first eligible date, preserved on re-arm.
# state/.daily-report/YYYY-MM-DD is pending, sending, or sent; .announced beside
# it suppresses repeated check output. Files are private and atomically replaced.
# Each check selects the latest due local date, coalescing missed days. Before
# today's time, yesterday is due, but no date before first arming is eligible.
# Queue publication precedes the announcement marker under the queue lock, so
# interruption cannot lose a wake; replayed wakes converge through claim.
# claim prints "claimed: <date>" only on pending -> sending (exit 3 otherwise).
# sent records confirmed delivery; retry requires proof of non-delivery and
# changes sending -> pending. Neither operation sends or re-announces anything.
# Sending records never expire automatically: an uncertain external send must
# be reconciled before retry, rather than risking duplicate email.
# .daily-report.lock serializes these operations with the portable wake locks.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1-}" in
  -h|--help) sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
ACTION=${1-}
error() {
  if [ "$ACTION" = check ]; then
    printf 'daily-report error: %s\n' "$*"
  else
    printf 'daily-report error: %s\n' "$*" >&2
  fi
  exit 1
}
case "$ACTION" in
  arm|disarm|check) [ "$#" -eq 1 ] || error "expected one command" ;;
  status|claim|sent|retry)
    [ "$#" -eq 2 ] && [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
      || error "expected a YYYY-MM-DD date"
    ;;
  *) error "unknown command; use --help" ;;
esac
[[ "${FM_HOME-}" = /* ]] && [ -d "$FM_HOME" ] || error "FM_HOME must name an absolute home"
STATE=${FM_STATE_OVERRIDE-$FM_HOME/state}
[ -n "$STATE" ] && [ ! -L "$STATE" ] || error "unsafe state directory"
SCHEDULE="$FM_HOME/config/daily-report"
TIME=
if [ "$ACTION" = arm ] || [ "$ACTION" = check ] || [ "$ACTION" = claim ]; then
  if [ ! -e "$SCHEDULE" ] && [ ! -L "$SCHEDULE" ]; then
    [ "$ACTION" = check ] && exit 0
    [ "$ACTION" = claim ] && { printf 'skip: schedule disabled\n'; exit 3; }
    error "configure config/daily-report before arming"
  fi
  [ -f "$SCHEDULE" ] && [ ! -L "$SCHEDULE" ] || error "unsafe schedule file"
  TIME=$(cat "$SCHEDULE") || error "cannot read schedule"
  case "$TIME" in
    off)
      [ "$ACTION" = check ] && exit 0
      [ "$ACTION" = claim ] && { printf 'skip: schedule disabled\n'; exit 3; }
      error "schedule is off"
      ;;
    on) TIME=18:07 ;;
    *) [[ "$TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || error "schedule must be off, on, or HH:MM" ;;
  esac
fi

umask 077
mkdir -p "$STATE" || error "cannot create state directory"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || error "unsafe state directory"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
RECORDS="$STATE/.daily-report"
[ ! -L "$RECORDS" ] || error "unsafe report directory"
mkdir -p "$RECORDS" || error "cannot create report directory"
[ -d "$RECORDS" ] || error "unsafe report directory"
DEVICE=$(fm_pr_file_device "$STATE") || error "cannot inspect state device"
LOCK="$STATE/.daily-report.lock"
LOCKED=0
QUEUE_LOCKED=0
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ "$QUEUE_LOCKED" -eq 0 ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  [ "$LOCKED" -eq 0 ] || fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait_max "$LOCK" 5 || error "report lock is busy"
LOCKED=1

read_record() {
  fm_pr_private_file_valid "$1" 600 "$DEVICE" || error "unsafe report record: $1"
  cat "$1" || error "cannot read report record"
}
write_record() {
  fm_pr_regular_destination_on_device_or_absent "$1" "$DEVICE" || error "unsafe destination: $1"
  TMP=$(mktemp "$STATE/.fm-daily-report.XXXXXX") || error "cannot create record"
  printf '%s\n' "$2" > "$TMP" || error "cannot write record"
  chmod 0600 "$TMP" || error "cannot protect record"
  mv -f -- "$TMP" "$1" || error "cannot publish record"
  TMP=
}
local_clock() {
  CLOCK=$(date '+%Y-%m-%d %H:%M') || error "cannot read local clock"
  TODAY=${CLOCK% *}
  NOW=${CLOCK#* }
  [[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    && [[ "$NOW" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || error "invalid local clock"
}
previous_day() {
  # Calendar arithmetic at noon avoids subtracting 24 hours across DST.
  date -d "$1 12:00 yesterday" '+%Y-%m-%d' 2>/dev/null \
    || date -j -v-1d -f '%Y-%m-%d %H:%M' "$1 12:00" '+%Y-%m-%d' 2>/dev/null
}

case "$ACTION" in
  arm)
    local_clock
    if [ ! -e "$RECORDS/start" ] && [ ! -L "$RECORDS/start" ]; then
      write_record "$RECORDS/start" "$TODAY"
    else
      read_record "$RECORDS/start" >/dev/null
    fi
    SHIM="$STATE/daily-report.check.sh"
    fm_pr_regular_destination_on_device_or_absent "$SHIM" "$DEVICE" || error "unsafe check destination"
    TMP=$(mktemp "$STATE/.fm-daily-report.XXXXXX") || error "cannot create check"
    printf '%s\n' '#!/usr/bin/env bash' \
      "export FM_HOME=$(printf '%q' "$FM_HOME")" \
      "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
      "exec $(printf '%q' "$SCRIPT_DIR/fm-daily-report.sh") check" > "$TMP" || error "cannot write check"
    chmod 0700 "$TMP" || error "cannot protect check"
    mv -f -- "$TMP" "$SHIM" || error "cannot publish check"
    TMP=
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-check-register.sh" daily-report \
      || error "check registration failed; fix and re-arm"
    ;;
  disarm)
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-check-unregister.sh" daily-report \
      || error "check retirement failed"
    ;;
  check)
    START=$(read_record "$RECORDS/start") || error "cannot read start date"
    [[ "$START" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || error "invalid start date"
    local_clock
    DUE=$TODAY
    if [[ "$NOW" < "$TIME" ]]; then
      DUE=$(previous_day "$TODAY") || error "cannot resolve yesterday"
    fi
    [[ "$DUE" < "$START" ]] && exit 0
    RECORD="$RECORDS/$DUE"
    if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
      VALUE=$(read_record "$RECORD") || error "cannot read report state"
      case "$VALUE" in pending|sending|sent) ;; *) error "invalid report state" ;; esac
    else
      write_record "$RECORD" pending
    fi
    if [ -e "$RECORD.announced" ] || [ -L "$RECORD.announced" ]; then
      [ "$(read_record "$RECORD.announced")" = "$DUE" ] || error "invalid announcement"
      exit 0
    fi
    # Persist before suppressing stdout. Date-specific keys retain older due
    # dates in a delayed drain; the watcher's extra row is safe through claim.
    LINE="daily-report due $DUE"
    KEY="$STATE/daily-report.check.sh"
    fm_lock_acquire_wait_max "$FM_WAKE_QUEUE_LOCK" 5 || error "wake queue is busy"
    QUEUE_LOCKED=1
    fm_wake_append_locked check "daily-report:$DUE" "check: $KEY: $LINE" || error "cannot queue report wake"
    write_record "$RECORD.announced" "$DUE"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    QUEUE_LOCKED=0
    printf '%s\n' "$LINE"
    ;;
  status|claim|sent|retry)
    DAY=$2
    RECORD="$RECORDS/$DAY"
    VALUE=$(read_record "$RECORD") || exit 1
    case "$VALUE" in pending|sending|sent) ;; *) error "invalid report state" ;; esac
    case "$ACTION:$VALUE" in
      status:*) printf '%s: %s\n' "$VALUE" "$DAY" ;;
      claim:pending) write_record "$RECORD" sending; printf 'claimed: %s\n' "$DAY" ;;
      claim:*) printf 'skip: %s %s\n' "$DAY" "$VALUE"; exit 3 ;;
      sent:sending|sent:sent) write_record "$RECORD" sent; printf 'sent: %s\n' "$DAY" ;;
      retry:sending) write_record "$RECORD" pending; printf 'pending: %s\n' "$DAY" ;;
      *) error "invalid transition $ACTION from $VALUE" ;;
    esac
    ;;
esac
