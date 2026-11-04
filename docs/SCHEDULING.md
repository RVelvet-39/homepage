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
