#!/usr/bin/env bash
# Public-interface tests for daily time gates, registered watcher delivery,
# catch-up, durable send claims, concurrency, and crash-safe wake publication.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
REPORT="$ROOT/bin/fm-daily-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-daily-report)
REAL_DATE=$(command -v date)
REAL_MV=$(command -v mv)

make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/config" "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = '+%Y-%m-%d %H:%M' ]; then
  printf '%s %s\n' "$TEST_DAY" "$TEST_TIME"
else
  exec "$REAL_DATE" "$@"
fi
SH
  chmod +x "$fakebin/date"
  printf '%s\n' "$home"
}

run_report() {
  local home=$1 day=$2 time=$3
  shift 3
  FM_HOME="$home" PATH="$home/fakebin:$PATH" REAL_DATE="$REAL_DATE" \
    TEST_DAY="$day" TEST_TIME="$time" TZ=America/Chicago bash "$REPORT" "$@"
}

test_disabled_and_invalid_config() {
  local home out status
  home=$(make_home disabled)
  out=$(run_report "$home" 2026-10-07 23:59 check) || fail "unconfigured check failed"
  [ -z "$out" ] || fail "unconfigured check emitted"
  assert_absent "$home/state/.daily-report" "disabled check wrote report state"
  printf 'off\n' > "$home/config/daily-report"
  out=$(run_report "$home" 2026-10-07 23:59 check) || fail "off check failed"
  [ -z "$out" ] || fail "off check emitted"
  printf '24:00\n' > "$home/config/daily-report"
  status=0
  out=$(run_report "$home" 2026-10-07 23:59 check) || status=$?
  expect_code 1 "$status" "invalid time"
  assert_contains "$out" 'daily-report error:' "malformed schedule must wake the session"
  assert_absent "$home/state/.daily-report" "invalid configuration wrote report state"
  status=0
  FM_HOME='' bash "$REPORT" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing explicit home"
  pass "disabled checks are silent and malformed schedules are actionable"
}

test_default_gate_and_history() {
  local home out
  home=$(make_home default)
  printf 'on\n' > "$home/config/daily-report"
  run_report "$home" 2026-10-07 10:00 arm >/dev/null || fail "arm failed"
  assert_present "$home/state/daily-report.check-trust" "arm did not register"
  out=$(run_report "$home" 2026-10-07 18:06 check) || fail "pre-gate check failed"
  [ -z "$out" ] || fail "default fired before 18:07"
  out=$(run_report "$home" 2026-10-07 18:07 check) || fail "due check failed"
  [ "$out" = 'daily-report due 2026-10-07' ] || fail "default threshold output: $out"
  out=$(run_report "$home" 2026-10-07 23:59 check) || fail "repeat check failed"
  [ -z "$out" ] || fail "same local date emitted twice"
  run_report "$home" 2026-10-07 23:59 disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/daily-report.check.sh" "disarm left check"
  assert_absent "$home/state/daily-report.check-trust" "disarm left trust"
  run_report "$home" 2026-10-07 23:59 arm >/dev/null || fail "re-arm failed"
  out=$(run_report "$home" 2026-10-07 23:59 check) || fail "re-arm check failed"
  [ -z "$out" ] || fail "re-arm deleted announcement history"
  pass "default 18:07 gate emits once and re-arming retains history"
}

test_custom_time_catchup_and_dst() {
  local home out
  home=$(make_home catchup)
  printf '09:15\n' > "$home/config/daily-report"
  run_report "$home" 2026-10-07 08:00 arm >/dev/null || fail "arm failed"
  out=$(run_report "$home" 2026-10-07 09:14 check) || fail "pre-gate failed"
  [ -z "$out" ] || fail "custom gate fired early"
  # No watcher ran for five days; a morning restart catches up with yesterday.
  out=$(run_report "$home" 2026-10-12 08:00 check) || fail "catch-up failed"
  [ "$out" = 'daily-report due 2026-10-11' ] || fail "catch-up did not select yesterday: $out"
  assert_absent "$home/state/.daily-report/2026-10-10" "catch-up replayed missed days"
  out=$(run_report "$home" 2026-10-12 09:15 check) || fail "today gate failed"
  [ "$out" = 'daily-report due 2026-10-12' ] || fail "custom gate did not fire"
  printf '00:30\n' > "$home/config/daily-report"
  out=$(run_report "$home" 2026-11-01 01:30 check) || fail "DST due failed"
  [ "$out" = 'daily-report due 2026-11-01' ] || fail "DST date incorrect"
  out=$(run_report "$home" 2026-11-01 01:00 check) || fail "repeated hour failed"
  [ -z "$out" ] || fail "repeated local hour emitted again"
  printf '18:07\n' > "$home/config/daily-report"
  out=$(run_report "$home" 2026-11-02 00:15 check) || fail "DST yesterday failed"
  [ -z "$out" ] || fail "DST calendar arithmetic did not choose November 1"
  out=$(run_report "$home" 2027-01-01 01:00 check) || fail "year rollover failed"
  [ "$out" = 'daily-report due 2026-12-31' ] || fail "year rollover wrong: $out"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" bash "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err") || fail "delayed drain failed"
  assert_contains "$out" 'daily-report due 2026-10-11' "delayed drain collapsed an earlier date"
  assert_contains "$out" 'daily-report due 2026-10-12' "delayed drain lost a due date"
  assert_contains "$out" 'daily-report due 2026-12-31' "delayed drain lost latest date"
  pass "custom threshold, latest-day catch-up, DST, and year rollover converge"
}

test_concurrent_check_and_send_claims() {
  local home out status p1 p2
  home=$(make_home concurrent)
  printf 'on\n' > "$home/config/daily-report"
  run_report "$home" 2026-10-07 18:07 arm >/dev/null || fail "arm failed"
  run_report "$home" 2026-10-07 18:07 check > "$home/a" & p1=$!
  run_report "$home" 2026-10-07 18:07 check > "$home/b" & p2=$!
  wait "$p1" || fail "first check failed"
  wait "$p2" || fail "second check failed"
  [ "$(cat "$home/a" "$home/b")" = 'daily-report due 2026-10-07' ] || fail "overlapping polls duplicated"
  (run_report "$home" 2026-10-07 18:07 claim 2026-10-07 > "$home/a"; printf '%s\n' "$?" > "$home/a.rc") & p1=$!
  (run_report "$home" 2026-10-07 18:07 claim 2026-10-07 > "$home/b"; printf '%s\n' "$?" > "$home/b.rc") & p2=$!
  wait "$p1" || fail "first claim process failed"
  wait "$p2" || fail "second claim process failed"
  [ "$(sort "$home/a.rc" "$home/b.rc" | tr '\n' ' ')" = '0 3 ' ] || fail "claims did not elect one sender"
  out=$(run_report "$home" 2026-10-08 10:00 status 2026-10-07) || fail "status failed"
  [ "$out" = 'sending: 2026-10-07' ] || fail "sending did not survive restart"
  status=0
  run_report "$home" 2026-10-09 10:00 claim 2026-10-07 >/dev/null || status=$?
  expect_code 3 "$status" "uncertain send never expires"
  run_report "$home" 2026-10-09 10:00 retry 2026-10-07 >/dev/null || fail "proved non-delivery retry failed"
  printf 'off\n' > "$home/config/daily-report"
  status=0
  run_report "$home" 2026-10-09 10:00 claim 2026-10-07 >/dev/null || status=$?
  expect_code 3 "$status" "disabled schedule refuses send claim"
  printf 'on\n' > "$home/config/daily-report"
  run_report "$home" 2026-10-09 10:00 claim 2026-10-07 >/dev/null || fail "retry claim failed"
  run_report "$home" 2026-10-09 10:00 sent 2026-10-07 >/dev/null || fail "delivery recording failed"
  run_report "$home" 2026-10-09 10:00 sent 2026-10-07 >/dev/null || fail "sent was not idempotent"
  status=0
  run_report "$home" 2026-10-09 10:00 claim 2026-10-07 >/dev/null || status=$?
  expect_code 3 "$status" "confirmed report cannot be claimed again"
  status=0
  run_report "$home" 2026-10-09 10:00 retry 2026-10-07 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "sent report cannot be retried"
  pass "overlapping checks and send claims elect one sender and preserve uncertainty"
}

test_durable_publication_and_unsafe_records() {
  local home out status
  home=$(make_home crash)
  printf 'on\n' > "$home/config/daily-report"
  run_report "$home" 2026-10-07 18:07 arm >/dev/null || fail "arm failed"
  cat > "$home/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in *.announced) exit 1 ;; esac
done
exec "$REAL_MV" "$@"
SH
  chmod +x "$home/fakebin/mv"
  export REAL_MV
  status=0
  run_report "$home" 2026-10-07 18:07 check >/dev/null || status=$?
  expect_code 1 "$status" "announcement publication interruption"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" bash "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err") || fail "drain failed"
  assert_contains "$out" 'daily-report due 2026-10-07' "interruption lost durable wake"
  rm "$home/fakebin/mv"
  out=$(run_report "$home" 2026-10-07 18:07 check) || fail "recovery failed"
  [ "$out" = 'daily-report due 2026-10-07' ] || fail "recovery did not finish announcement"
  ln "$home/state/.daily-report/2026-10-07" "$home/alias"
  status=0
  run_report "$home" 2026-10-07 18:07 claim 2026-10-07 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "hard-linked send record"
  rm "$home/alias"
  mv "$home/state/.daily-report/2026-10-07" "$home/outside"
  ln -s "$home/outside" "$home/state/.daily-report/2026-10-07"
  status=0
  run_report "$home" 2026-10-07 18:07 claim 2026-10-07 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "symlink send record"
  [ "$(cat "$home/outside")" = pending ] || fail "unsafe record changed its target"
  pass "wake survives interrupted publication and unsafe send records fail closed"
}

test_registered_watcher_wake() {
  local home out status
  home=$(make_home watcher)
  printf 'on\n' > "$home/config/daily-report"
  run_report "$home" 2026-10-07 18:07 arm >/dev/null || fail "arm failed"
  status=0
  FM_HOME="$home" PATH="$home/fakebin:$PATH" REAL_DATE="$REAL_DATE" \
    TEST_DAY=2026-10-07 TEST_TIME=18:07 FM_POLL=1 FM_CHECK_INTERVAL=1 \
    FM_HEARTBEAT=999999 bash "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 \
    > "$home/out" 2> "$home/err" || status=$?
  expect_code 0 "$status" "registered daily watcher"
  assert_contains "$(cat "$home/out")" 'daily-report due 2026-10-07' "watcher did not deliver due wake"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" bash "$ROOT/bin/fm-wake-drain.sh" 2> "$home/drain.err") || fail "drain failed"
  assert_contains "$out" 'daily-report due 2026-10-07' "watcher wake was not durable"
  run_report "$home" 2026-10-07 18:07 claim 2026-10-07 >/dev/null || fail "first claim failed"
  status=0
  run_report "$home" 2026-10-07 18:07 claim 2026-10-07 >/dev/null || status=$?
  expect_code 3 "$status" "replayed watcher wake"
  pass "real watcher executes the registered snapshot and replay cannot resend"
}

test_disabled_and_invalid_config
test_default_gate_and_history
test_custom_time_catchup_and_dst
test_concurrent_check_and_send_claims
test_durable_publication_and_unsafe_records
test_registered_watcher_wake
