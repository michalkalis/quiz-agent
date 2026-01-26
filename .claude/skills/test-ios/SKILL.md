---
name: test-ios
description: Run iOS unit tests for CarQuiz app. Use after iOS code changes.
disable-model-invocation: true
allowed-tools: Bash
model: haiku
argument-hint: "[unit|ui|all|specific-test-name]"
---

# Run iOS Tests

Run iOS tests for the CarQuiz app.

## Based on $ARGUMENTS:

### "unit" or no argument
Run unit tests only:
```bash
cd apps/ios-app/CarQuiz && xcodebuild test \
  -scheme CarQuiz-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing CarQuizTests \
  2>&1 | xcpretty --color || cat
```

### "ui"
Run UI tests:
```bash
cd apps/ios-app/CarQuiz && xcodebuild test \
  -scheme CarQuiz-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing CarQuizUITests \
  2>&1 | xcpretty --color || cat
```

### "all"
Run all tests (unit + UI):
```bash
cd apps/ios-app/CarQuiz && xcodebuild test \
  -scheme CarQuiz-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | xcpretty --color || cat
```

### Specific test name
Run only that test:
```bash
cd apps/ios-app/CarQuiz && xcodebuild test \
  -scheme CarQuiz-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing "CarQuizTests/$ARGUMENTS" \
  2>&1 | xcpretty --color || cat
```

## Report
- Total tests run
- Passed / Failed count
- Details of any failures
- Suggest fixes if tests fail
