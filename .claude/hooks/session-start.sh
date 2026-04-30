#!/bin/bash
# Session start hook - displays available tools and efficiency tips

# Colors (ANSI escape codes)
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
DIM='\033[2m'
RESET='\033[0m'
BOLD='\033[1m'

# Check if best practices check is overdue
LAST_CHECK_FILE="$CLAUDE_PROJECT_DIR/.claude/.last-check"
CHECK_REMINDER=""
if [ ! -f "$LAST_CHECK_FILE" ]; then
    CHECK_REMINDER="Run /best-practices for first-time setup review"
else
    LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null)
    NOW=$(date +%s)
    if [[ "$LAST_CHECK" =~ ^[0-9]+$ ]]; then
        DAYS_SINCE=$(( (NOW - LAST_CHECK) / 86400 ))
        if [ "$DAYS_SINCE" -ge 7 ]; then
            CHECK_REMINDER="Best practices check is ${DAYS_SINCE} days overdue"
        fi
    fi
fi

echo ""
echo -e "${CYAN}╭─────────────────────────────────────────────────────────╮${RESET}"
echo -e "${CYAN}│${RESET}  ${BOLD}AVAILABLE TOOLS FOR quiz-agent${RESET}                        ${CYAN}│${RESET}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${RESET}"
echo -e "${CYAN}│${RESET}  ${YELLOW}DEV SKILLS${RESET} ${DIM}(invoke with /name)${RESET}                         ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/verify-api${RESET}     - Check iOS<->Backend model sync     ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/start-local${RESET}    - Start backend/web services         ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/catchup${RESET}        - Summarize branch changes           ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/todo${RESET}           - Manage local todo list             ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/summarize${RESET}      - Handoff plan for fresh session     ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/test-ios${RESET}       - Run iOS unit tests                 ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/test-backend${RESET}   - Run pytest suite                   ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/regression${RESET}     - Run iOS regression scenarios       ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/build-ios${RESET}      - Build iOS app                      ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/gen-questions${RESET}  - Generate quiz questions             ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/verify-qs${RESET}     - Verify question accuracy           ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/score-qs${RESET}      - Score questions (5 dimensions)    ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/deploy${RESET}         - Deploy backend to Fly.io          ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/best-practices${RESET} - Check Claude Code setup (weekly)   ${CYAN}│${RESET}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${RESET}"
echo -e "${CYAN}│${RESET}  ${YELLOW}PM & DESIGN${RESET} ${DIM}(invoke with /name)${RESET}                        ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/write-prd${RESET}      - Interactive PRD generator          ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/user-stories${RESET}   - Generate user stories (BDD)        ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/research${RESET}       - Deep research with sources         ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/competitive-analysis${RESET} - Competitor feature matrix    ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}/review-ui${RESET}      - Screenshot HIG analysis            ${CYAN}│${RESET}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${RESET}"
echo -e "${CYAN}│${RESET}  ${YELLOW}AGENTS${RESET} ${DIM}(delegate with \"use X agent\")${RESET}                   ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}ios-tester${RESET}      - Run iOS tests, report failures     ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}backend-tester${RESET}  - Run pytest, report failures        ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}code-reviewer${RESET}   - Review recent changes              ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    ${GREEN}security-reviewer${RESET} - OWASP & secret leak scan        ${CYAN}│${RESET}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${RESET}"
echo -e "${CYAN}│${RESET}  ${YELLOW}HOOKS${RESET} ${DIM}(automatic)${RESET}                                      ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    Swift auto-format (swiftformat on .swift edits)      ${CYAN}│${RESET}"
echo -e "${CYAN}│${RESET}    Python auto-test (pytest on backend app edits)      ${CYAN}│${RESET}"

# Show check reminder if overdue
if [ -n "$CHECK_REMINDER" ]; then
    echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${RESET}"
    echo -e "${CYAN}│${RESET}  ${YELLOW}⚠${RESET}  ${CHECK_REMINDER}${RESET}"
fi

echo -e "${CYAN}╰─────────────────────────────────────────────────────────╯${RESET}"
echo ""

exit 0
