---
name: check-crashes
description: Query Sentry for iOS crashes, structured logs, and user feedback to autonomously debug TestFlight issues
allowed-tools: Bash, Read, Grep, Glob, WebFetch
argument-hint: "[recent|issue-ID|--summary|--logs [query]|--feedback]"
---

# Check Crashes / Logs / Feedback from Sentry

One-stop Sentry query command. Covers crashes, structured logs (experimental), and user-feedback submissions (shake-to-report) from CarQuiz iOS.

## Prerequisites

`SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `SENTRY_PROJECT` must be set (they live in `.env`).

## PII Note

iOS `beforeSend` scrubber in `CarQuizApp.swift` redacts raw user speech/transcripts before events leave the device. Seeing `[REDACTED]` in event data is expected, not a bug.

## Based on $ARGUMENTS:

### No argument or "recent" — richer default snapshot
Fetch unresolved issues + latest user feedback + recent error-level logs:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&sort=date&limit=10" | python3 -m json.tool
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/user-feedback/?limit=5" | python3 -m json.tool
# Recent error logs (see --logs below for endpoint notes)
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/organizations/$SENTRY_ORG/events/?dataset=ourlogs&field=timestamp&field=message&field=severity&query=severity:error&statsPeriod=24h&per_page=10" | python3 -m json.tool
```

For each issue, fetch the latest event:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/issues/<ISSUE_ID>/events/latest/" | python3 -m json.tool
```

### Specific issue ID (e.g., "12345")
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/issues/$ARGUMENTS/" | python3 -m json.tool
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/issues/$ARGUMENTS/events/latest/" | python3 -m json.tool
# Download any attachments (screenshots, view hierarchy)
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/events/<EVENT_ID>/attachments/" | python3 -m json.tool
```

### "--summary"
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&sort=freq&limit=5&statsPeriod=24h" | python3 -m json.tool
```

### "--logs [query]" — Sentry Structured Logs (experimental)
Primary (organization events API with `ourlogs` dataset — undocumented but used by Sentry UI as of 2025):
```bash
# Default: recent error logs in last 24h. Pass extra query terms via $ARGUMENTS.
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/organizations/$SENTRY_ORG/events/?dataset=ourlogs&field=timestamp&field=message&field=severity&field=trace&query=${LOG_QUERY:-severity:error}&statsPeriod=24h&per_page=50" | python3 -m json.tool
```
Fallback candidate URLs (verify the one that returns data in your org):
- `https://sentry.io/api/0/organizations/$SENTRY_ORG/events/?dataset=events&query=event.type:log ...`
- Dedicated `/logs/` endpoint, if rolled out: `https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/logs/`

Sources: Sentry docs "Logs / Getting Started" (https://docs.sentry.io/product/explore/logs/getting-started/) does not yet document the query API; the `ourlogs` dataset is the shape used by sentry-cocoa SDK v8+ and the Sentry web UI. Confirm with `curl -v` and adjust on the fly if the response is empty.

### "--feedback" — User Feedback submissions
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/user-feedback/?limit=20" | python3 -m json.tool
```
Note: this is the legacy User Reports endpoint. New Feedback Widget submissions (sentry-cocoa shake-to-report) appear as issues with `issue.category:feedback`. If the above returns empty, query issues instead:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=issue.category:feedback&limit=20" | python3 -m json.tool
```
Screenshots are attachments on the linked event — fetch via the `/events/<EVENT_ID>/attachments/` endpoint shown above. Source: https://docs.sentry.io/api/projects/list-a-projects-user-feedback/

## Analysis Steps

1. **Parse the stack trace** — identify crashing file, line, function.
2. **Read the source file** — use Read tool at the crash location.
3. **Surface quiz context** — parse `contexts["quiz.current"]` (questionId, category) and `tags["quiz.state"]` on the event; this often points straight at the offending question/state.
4. **Download attachments** — when the event has `attachments`, pull screenshots and view-hierarchy JSON via the attachments endpoint; reference them in the report.
5. **Replay** — if the event has a `replay_id`, surface `https://sentry.io/organizations/$SENTRY_ORG/replays/<replay_id>/` so the user can open the session replay.
6. **Correlate with logs** — run `--logs trace:<trace_id>` using the event's `trace_id` to pull the structured-log breadcrumbs around the crash.
7. **Read user feedback** — check `--feedback` for a human-written complaint tied to the same issue (`issue_id`).
8. **Identify root cause** — nil unwrap, index OOB, threading, API mismatch, etc.
9. **Suggest fix** — concrete code change with file:line.

## Report Format

For each crash / feedback item:
- **Title** + **Issue/Feedback ID**
- **Frequency** (events / users affected)
- **Quiz context** (`quiz.state`, `quiz.current.questionId`, category) when present
- **Stack trace** key frames (file:line)
- **Attachments** — screenshot path, view-hierarchy summary, replay URL
- **User feedback** — verbatim comment if linked
- **Root cause** + **Fix** + **Severity** (Critical / High / Medium / Low)

## Notes
- Focus on actionable issues; skip resolved / clearly edge-case reports.
- Obfuscated symbols → dSYMs may need uploading (`sentry-cli debug-files upload`).
- Treat `[REDACTED]` strings as expected PII scrubbing, not data loss.
