---
name: daily-report
description: Load on a daily-report due or daily-report error check wake, and before configuring or reconciling the daily report schedule.
user-invocable: false
metadata:
  internal: true
---

# Daily report

[`bin/fm-daily-report.sh`](../../../bin/fm-daily-report.sh)'s header and `--help` own the commands, daily records, and send-state transitions.
[`docs/configuration.md`](../../../docs/configuration.md#daily-report-configdaily-report) owns schedule setup and timing limits.
This skill owns session handling of a `daily-report due YYYY-MM-DD` or `daily-report error` check wake.
Use the ordinary wake drain and acknowledgement protocol.
The journaled wake and the watcher's captured-output wake may both appear for one date; the durable claim is the send authority for both.

## Compose and send

1. On an error wake, diagnose the named schedule or state problem and report it through the normal firstmate channel.
   Never treat an error as a report-send request.
2. On a due wake, inspect that date with `FM_HOME="$FM_HOME" bash bin/fm-daily-report.sh status YYYY-MM-DD`.
   A `sent` record is already handled.
   A `sending` record requires the reconciliation below; never send again just because the wake was replayed.
3. For a pending date, compose a plain-text email from current fleet state and recorded outcomes since the last confirmed report, including any gap caused by a stopped session.
   Use the structured fleet view and targeted reconciliation rather than treating status tails as current truth.
   Put critical or urgent items first, followed by what went out (with full PR or deployment URLs), what to verify by hand (concrete steps and expected results), what is in progress, and what needs the captain (the decision and consequence of waiting).
   Keep empty sections short and state material uncertainty plainly.
   Save the body and the supporting delivery evidence in the home's private `data/daily-reports/YYYY-MM-DD/` directory.
4. Resolve the captain's recipient and approved sending tool from the home's preferences and available tools before claiming.
   If either is missing, keep the report pending, record the missing information as an open captain call, and acknowledge the wake only after that follow-up is durable.
   A configured schedule authorizes its daily email through the established recipient and tool; do not ask for approval on every report.
   Critical or urgent items may additionally use an already approved email-to-text recipient, with a concise alert and the daily report date.
   Persist evidence for each channel separately so an email-to-text retry cannot resend the daily email.
5. Immediately before sending the daily email, run `FM_HOME="$FM_HOME" bash bin/fm-daily-report.sh claim YYYY-MM-DD`.
   Send only when that invocation exits zero and prints `claimed: YYYY-MM-DD`.
   Exit 3 means disabled, already claimed, or already sent; inspect rather than sending.
6. Send once with the session's established mail tool, retain its confirmation or message identifier with the saved body, then run `FM_HOME="$FM_HOME" bash bin/fm-daily-report.sh sent YYYY-MM-DD`.
   Acknowledge the wake after the confirmed delivery and durable `sent` record, or after recording a durable unresolved follow-up.

## Interrupted or uncertain delivery

The daily check is a wake scheduler and contains no email credentials or transport.
It journals the wake before suppressing repeat output, and a restarted session drains that wake through the existing queue.
A stopped watcher evaluates the latest due date on its next normal check, coalescing days that never produced wakes instead of issuing one email for every missed day.
Previously queued dates remain obligations: handle their durable states through the same procedure before acknowledging their wakes.

A `sending` record never expires automatically.
Inspect the established tool's delivery history and saved evidence before deciding what happened.
If delivery is confirmed, record `sent` without another email.
Only when non-delivery is proved may firstmate run `retry YYYY-MM-DD`, claim again, and send.
If delivery cannot be determined, preserve `sending`, record the uncertainty as an open captain call, and do not retry automatically.
Exactly-once delivery cannot be guaranteed across an external mail-tool call and a local state write; this retained uncertainty prevents automatic duplicates across that gap.
Do not hand-delete records or use re-arming to bypass a claim.
