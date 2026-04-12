---
name: check-crashes
description: Query Sentry for recent iOS crashes and analyze them for debugging
allowed-tools: Bash, Read, Grep, Glob, WebFetch
argument-hint: "[recent|issue-ID|--summary]"
---

# Check Crashes from Sentry

Query the Sentry API for recent crash reports from the CarQuiz iOS app and analyze them.

## Prerequisites

- `SENTRY_AUTH_TOKEN` environment variable must be set
- `SENTRY_ORG` environment variable must be set (Sentry organization slug)
- `SENTRY_PROJECT` environment variable must be set (Sentry project slug, e.g. "carquiz-ios")

## Based on $ARGUMENTS:

### No argument or "recent"
Fetch the 10 most recent unresolved issues:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&sort=date&limit=10" | python3 -m json.tool
```

For each issue, fetch the latest event to get the full stack trace:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/issues/<ISSUE_ID>/events/latest/" | python3 -m json.tool
```

### Specific issue ID (e.g., "12345")
Fetch full details and latest event for that issue:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/issues/$ARGUMENTS/" | python3 -m json.tool
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/issues/$ARGUMENTS/events/latest/" | python3 -m json.tool
```

### "--summary"
Fetch issue stats for the last 24 hours:
```bash
curl -s -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$SENTRY_ORG/$SENTRY_PROJECT/issues/?query=is:unresolved&sort=freq&limit=5&statsPeriod=24h" | python3 -m json.tool
```

## Analysis Steps

After fetching crash data:

1. **Parse the stack trace** — identify the crashing file, line, and function
2. **Read the source file** — use Read tool to examine the code at the crash location
3. **Identify root cause** — analyze the crash context (nil unwrap, index out of bounds, threading issue, etc.)
4. **Check related code** — look for similar patterns that might also crash
5. **Suggest fix** — provide a concrete code fix with explanation

## Report Format

For each crash, report:
- **Title**: Issue title from Sentry
- **Frequency**: How many times it occurred, how many users affected
- **Stack trace**: Key frames (file:line)
- **Root cause**: What went wrong and why
- **Fix**: Concrete code change to resolve it
- **Severity**: Critical / High / Medium / Low

## Notes
- Focus on actionable crashes — skip issues that are clearly edge cases or already resolved
- If stack traces reference obfuscated symbols, note that dSYMs may need uploading
- Cross-reference with the codebase to provide file paths and line numbers
