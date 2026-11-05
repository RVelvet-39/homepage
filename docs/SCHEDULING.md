# Daily scheduling — intake contract

Status: draft. Nothing here is automated yet; this is the contract the cron job and
skill will implement once the open decisions below are settled.

## Principle

Working hours are **not fixed**. Hours vary by day, wake time varies (06:30 some days,
later others), and location changes during the day. The planner therefore never assumes
a window — every day is defined by input from Reina.

## Intake — one short message, any wording

The planner needs three things, in any order:

1. **Start + energy** — "up 6:30", "slow start", "slept badly".
2. **Hard anchors** — anything immovable: class, appointment, call, travel. Time-boxed.
3. **Location changes** — "campus until 15", "at the cafe 10–12", "back home after 16".
4. (optional) **Must-dos** — what has to land today, if the task list is not the source.

If intake is missing, the job asks once. It does not invent a day.

## Fixed weekly anchors (confirmed by Reina 2026-11-05)

Stated in chat on 2026-11-05, all in `Europe/London`, all written as `TRANSP:OPAQUE` with a
30-minute `VALARM`:

| Anchor | Days | Time | End | UID |
|---|---|---|---|---|
| School | Mon–Thu | 10:30 | 19:00 | `aaf78652-12c5-480d-8a59-ec2cfdb43709` |
| Work (Saturday shift) | Sat | 11:00 | 22:00 | `e43c7324-4386-4756-adc7-c21b200d1ffc` |
| Work (Sunday shift) | Sun | 11:00 | 20:00 | `6a5ef780-fdd5-4806-84a2-cff8f83f09c2` |

- School has **no `UNTIL`** — Reina does not know the term end, so it recurs open-ended and must be
  re-confirmed, not assumed to have stopped.
- Friday is the only weekday with no recurring anchor stated so far.
- Stale against this: the Thursday `Wake` / `Bus` / `Class` routine (06:30 / 06:50–08:50 /
  09:00–13:30) now overlaps School. Reina said the class is "on hold"; the events were left in place
  pending her decision, not deleted.
- Consequence: the "working hours are not fixed" principle below still governs *daily* planning, but
  the weekly shape is now largely fixed, so any study block has to fit Friday or the edges of the day.

## What gets produced

- Events in `/lobelia/schedule/`, each tagged `CATEGORIES:ruko` and `TRANSP:TRANSPARENT`
  (free, i.e. "proposed work block" rather than "committed appointment").
- Hard anchors are never modified or moved. Only the gaps are filled.
- Travel buffers are inserted around location changes, sized by the stated route.
- On new information the planner replaces **only** `ruko`-tagged blocks. Everything Reina
  wrote stays untouched.

## Hard rules

- No event is deleted without explicit per-event confirmation.
- No attendee invitations, no outbound mail.
- If the day is already full, the output is "it does not fit" plus what to drop — not a
  silently oversubscribed calendar.

## Open decisions

- **Intake channel**: chat message when the day starts, a cron prompt at a time she sets,
  or an intake event in the calendar.
- **Task source of truth**: calendar VTODO, Memos, or the intake message itself.
- **Cadence**: one pass per morning, or a week plan revised daily.

## Decisions so far (2026-11-05)

**Task source: Memos.** Notes stay the inbox; the planner reads them instead of a second
backlog. Needs a Memos access token at `~/.config/memos/token` (mode 600, outside git).
Convention to be confirmed: memos tagged `#task`, with `- [ ]` lines as open items.

**Reminders: cron, quiet by default.** `scripts/cal.sh remind 15` prints only events
starting within 15 minutes and records what it already announced in
`~/.local/state/selfhost/cal-reminded.json`, so a 10-minute tick cannot repeat itself.
Verified: first call printed `⏰ in 8 min: …`, the second call printed nothing.

**Time zones.** The host clock is UTC and busybox `date` ignores `TZ`; all date math is
done in Python `zoneinfo` with `CAL_TZ=Europe/London` (current region). Cron expressions are host-local
(UTC), so a fixed London wall-clock time must be converted — prefer intervals (`every
10m`) for reminders, and (see next point) for the daily plan.

**Daily plan: triggered by Reina, not by a clock.** Her wake time varies, so the plan job
runs when she says her day started. A cron prompt is a fallback she can set to a time she
picks, never a fixed 06:30 assumption.

## Calendar helper

`scripts/cal.sh` (wrapper around `scripts/cal.py`, venv at `~/.venvs/caldav`):

```
cal.sh today
cal.sh next 30
cal.sh remind 15
cal.sh list 7
cal.sh add "Write docs" 09:00 90                  # ruko-tagged, TRANSPARENT
cal.sh add "Wake" 06:30 30 --days we --anchor     # weekly, TRANSP:OPAQUE
cal.sh del <uid> --yes                            # deletion refuses without --yes
```

Verified against the live calendar: add → list → today → remind → del, and a recurring
anchor (`RRULE:FREQ=WEEKLY;BYDAY=WE`, `DTSTART;TZID=Europe/London`, `TRANSP:OPAQUE`) that
expanded to two Wednesdays before being deleted.

## Standing cron

| Job | Schedule | Mode | Script | State |
|---|---|---|---|---|
| calendar reminders, 15 min lead (`f848123e6379`) | `every 10m` | `no_agent` | `~/.hermes/scripts/cal-remind.sh` → `cal.sh remind 15` | **paused 2026-11-05** |

Empty stdout sends nothing, so it stays quiet unless an event is within 15 minutes.
Delivery: the Discord thread.

**Paused** because events now carry server-side `VALARM` (`--alarm`), which the phone's
calendar app fires locally through DAVx5 — the Discord ping duplicated it. Resume with
`cronjob_manage action=resume job_id=f848123e6379` if phone sync is unavailable or for
blocks created ad-hoc during a plan run. It did fire on schedule while enabled
(last run 08:41, status ok).

## Alarms

`cal.sh add … --alarm N` writes `ACTION:DISPLAY` + `TRIGGER:-PT<N>M` inside the event, so
the alert belongs to the event, not to this agent. Applied to the Thursday routine: Wake
at 0 min, Bus 10 min, Class 10 min. Requires a phone calendar app that syncs the DAVx5
account *and* has notifications enabled — Android calendars are silent by default.
