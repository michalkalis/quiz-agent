---
name: build-ios
description: Build iOS app to verify compilation. Use after code changes.
disable-model-invocation: true
allowed-tools: Bash
model: haiku
argument-hint: "[local|prod|clean]"
---

# Build iOS App

Build the CarQuiz iOS app.

## Based on $ARGUMENTS:

### "local" or no argument
Build with Local environment (localhost):
```bash
cd apps/ios-app/CarQuiz && xcodebuild \
  -scheme CarQuiz-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug \
  build \
  2>&1 | xcpretty --color || cat
```

### "prod"
Build with Production environment:
```bash
cd apps/ios-app/CarQuiz && xcodebuild \
  -scheme CarQuiz-Prod \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Release \
  build \
  2>&1 | xcpretty --color || cat
```

### "clean"
Clean and rebuild:
```bash
cd apps/ios-app/CarQuiz && xcodebuild clean && xcodebuild \
  -scheme CarQuiz-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build \
  2>&1 | xcpretty --color || cat
```

## Report
- Build success/failure
- Any warnings or errors
- Build time if successful
