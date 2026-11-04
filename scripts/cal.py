#!/usr/bin/env python3
"""Minimal CalDAV helper for the shared lobelia calendar.

Reads credentials from a file (never argv, never chat):
    ~/.config/radicale/ruko.pass        chmod 600
Environment overrides:
    CAL_URL    default https://hyacinth.angora-puffin.ts.net:8446/
    CAL_CAL    default /lobelia/schedule/
    CAL_USER   default lobelia
    CAL_TZ     default Europe/London

Commands:
    today                     events for today
    next [MINUTES]            events starting within N minutes (quiet if none)
    remind [LEAD]             due-soon events, deduped (quiet cron mode)
    list [DAYS]               next N days (default 7)
    add SUMMARY START [END|MINUTES] [--days mo,we] [--anchor]
                              e.g. add "Write docs" 09:00 90
                                   add "Wake" 06:30 30 --days we --anchor
    del UID --yes             delete one event (requires --yes)
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import caldav
from icalendar import Calendar, Event

URL = os.environ.get("CAL_URL", "https://hyacinth.angora-puffin.ts.net:8446/")
CAL_PATH = os.environ.get("CAL_CAL", "/lobelia/schedule/")
USER = os.environ.get("CAL_USER", "lobelia")
PASS_FILE = Path(os.environ.get("CAL_PASS_FILE", "~/.config/radicale/ruko.pass")).expanduser()
TZ = ZoneInfo(os.environ.get("CAL_TZ", "Europe/London"))

# Weekly recurrence: RRULE BYDAY codes.
DAYS = {"mo": 0, "tu": 1, "we": 2, "th": 3, "fr": 4, "sa": 5, "su": 6}
BYDAY = {v: k.upper() for k, v in DAYS.items()}


def password() -> str:
    if not PASS_FILE.exists():
        sys.exit(f"credential file missing: {PASS_FILE}")
    return PASS_FILE.read_text().strip()


def calendar():
    client = caldav.DAVClient(url=URL, username=USER, password=password())
    return client.calendar(url=URL.rstrip("/") + CAL_PATH)


def events_between(start: datetime, end: datetime):
    cal = calendar()
    out = []
    for ev in cal.search(start=start, end=end, event=True, expand=True):
        comp = None
        try:
            comps = ev.icalendar_instance.walk("VEVENT")
            comp = comps[0] if comps else None
        except Exception:
            pass
        if comp is None:
            continue
        dtstart = comp.get("DTSTART")
        if dtstart is None:
            continue
        s = dtstart.dt
        if isinstance(s, datetime) is False:  # all-day event -> date
            s = datetime.combine(s, time.min, TZ)
        elif s.tzinfo is None:
            s = s.replace(tzinfo=TZ)
        dtend = comp.get("DTEND")
        e = None
        if dtend is not None:
            e = dtend.dt
            if isinstance(e, datetime) is False:
                e = datetime.combine(e, time.min, TZ)
            elif e.tzinfo is None:
                e = e.replace(tzinfo=TZ)
        out.append((s, e, str(comp.get("SUMMARY", "(no summary)")), str(comp.get("UID", ""))))
    return sorted(out)


def fmt(s: datetime, e: datetime | None) -> str:
    if e:
        return f"{s.strftime('%a %H:%M')}-{e.strftime('%H:%M')}"
    return s.strftime("%a %H:%M")


def cmd_today(_args):
    now = datetime.now(TZ)
    start = datetime.combine(now.date(), time.min, TZ)
    evs = events_between(start, start + timedelta(days=1))
    if not evs:
        print("no events today")
        return
    for s, e, summary, _uid in evs:
        print(f"{fmt(s, e)}  {summary}")


def cmd_next(args):
    minutes = int(args[0]) if args else 30
    now = datetime.now(TZ).replace(second=0, microsecond=0)
    evs = events_between(now, now + timedelta(minutes=minutes))
    for s, e, summary, _uid in evs:
        delta = int((s - now).total_seconds() // 60)
        when = "now" if delta <= 0 else f"in {delta} min"
        print(f"⏰ {when}: {summary} ({fmt(s, e)})")


def cmd_list(args):
    days = int(args[0]) if args else 7
    now = datetime.now(TZ)
    evs = events_between(now, now + timedelta(days=days))
    if not evs:
        print(f"nothing in the next {days} days")
        return
    for s, e, summary, uid in evs:
        print(f"{s.strftime('%Y-%m-%d')} {fmt(s, e)[-11:]}  {summary}  [{uid}]")


def cmd_add(args):
    if len(args) < 2:
        sys.exit('usage: add "SUMMARY" HH:MM [MINUTES|HH:MM] [--days mo,we] [--anchor]')
    summary = args[0]
    start_t = time.fromisoformat(args[1])
    rest = args[2:]

    recur_days: list[int] = []
    anchor = False
    positional: list[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--days" and i + 1 < len(rest):
            recur_days = [DAYS[d.strip().lower()[:2]] for d in rest[i + 1].split(",") if d.strip()]
            i += 2
        elif a == "--anchor":
            anchor = True
            i += 1
        else:
            positional.append(a)
            i += 1

    now = datetime.now(TZ)
    start = datetime.combine(now.date(), start_t, TZ)

    if recur_days:
        # first occurrence: the next matching weekday at that time
        while start.weekday() not in recur_days or start < now - timedelta(minutes=1):
            start += timedelta(days=1)
    elif start < now - timedelta(hours=1):
        start += timedelta(days=1)  # past slot means tomorrow

    if positional and ":" in positional[0]:
        end = datetime.combine(start.date(), time.fromisoformat(positional[0]), TZ)
        if end <= start:
            end += timedelta(days=1)
    else:
        minutes = int(positional[0]) if positional else 60
        end = start + timedelta(minutes=minutes)

    ev = Event()
    ev.add("summary", summary)
    ev.add("dtstart", start)
    ev.add("dtend", end)
    ev.add("categories", ["ruko"])
    # anchors are real commitments (busy); generated work blocks stay transparent
    ev.add("transp", "OPAQUE" if anchor else "TRANSPARENT")
    if recur_days:
        ev.add("rrule", {"freq": "weekly", "byday": [BYDAY[d] for d in recur_days]})

    cal = Calendar()
    cal.add("prodid", "-//ruko//selfhost//EN")
    cal.add("version", "2.0")
    cal.add_component(ev)
    calendar().save_event(cal.to_ical().decode())

    kind = "anchor" if anchor else "block"
    when = f"every {','.join(BYDAY[d] for d in recur_days)}" if recur_days else start.strftime("%Y-%m-%d")
    print(f"added {kind} {when} {start.strftime('%H:%M')}-{end.strftime('%H:%M')}  {summary}")


def cmd_del(args):
    if not args or "--yes" not in args:
        sys.exit("usage: del UID --yes   (deletion needs explicit confirmation)")
    uid = [a for a in args if a != "--yes"][0]
    cal = calendar()
    ev = cal.event_by_uid(uid)
    ev.delete()
    print(f"deleted {uid}")


def cmd_remind(args):
    """Print events starting within LEAD minutes that have not been reminded yet.

    Quiet by default: prints nothing when nothing is due. Used by a no_agent cron
    job, where empty stdout means "send no message".
    """
    import json

    lead = int(args[0]) if args else 15
    state_path = Path(os.environ.get("CAL_STATE", "~/.local/state/selfhost/cal-reminded.json")).expanduser()
    state_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        seen = json.loads(state_path.read_text())
    except Exception:
        seen = {}

    now = datetime.now(TZ).replace(second=0, microsecond=0)
    evs = events_between(now, now + timedelta(minutes=lead))
    fresh = []
    for s, e, summary, uid in evs:
        key = f"{uid}@{s.isoformat()}"
        if key in seen:
            continue
        seen[key] = now.isoformat()
        fresh.append((s, e, summary, uid))

    # prune anything older than 2 days so the file cannot grow forever
    cutoff = (now - timedelta(days=2)).isoformat()
    seen = {k: v for k, v in seen.items() if v >= cutoff}
    state_path.write_text(json.dumps(seen, indent=0))

    for s, e, summary, _uid in fresh:
        delta = int((s - now).total_seconds() // 60)
        when = "now" if delta <= 0 else f"in {delta} min"
        print(f"⏰ {when}: {summary} ({fmt(s, e)})")


COMMANDS = {
    "today": cmd_today,
    "next": cmd_next,
    "remind": cmd_remind,
    "list": cmd_list,
    "add": cmd_add,
    "del": cmd_del,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](sys.argv[2:])
