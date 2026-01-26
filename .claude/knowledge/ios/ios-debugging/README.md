# iOS Debugging Guide

Use this knowledge when troubleshooting network issues, audio problems, build failures, or JSON decoding errors.

## Quick Reference

| Problem | Reference |
|---------|-----------|
| Network requests failing | [network-debugging.md](references/network-debugging.md) |
| Audio not working | [audio-debugging.md](references/audio-debugging.md) |
| Build/Xcode issues | [build-issues.md](references/build-issues.md) |
| JSON decoding errors | [decoding-errors.md](references/decoding-errors.md) |

## Decision Tree

### 1. Network request failing?
Check response in Console:
```swift
print("📄 Response: \(String(data: data, encoding: .utf8) ?? "nil")")
```
→ See [network-debugging.md](references/network-debugging.md)

### 2. Audio not playing/recording?
Check permissions and format:
- Microphone permission granted?
- Audio format supported? (iOS doesn't play OggOpus)
- Audio session activated?
→ See [audio-debugging.md](references/audio-debugging.md)

### 3. Build failing?
Clean and rebuild:
```bash
# Clean DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/

# Clean build folder
Cmd+Shift+K in Xcode
```
→ See [build-issues.md](references/build-issues.md)

### 4. JSON decoding error?
Log raw response and error details:
```swift
if let decodingError = error as? DecodingError {
    switch decodingError {
    case .keyNotFound(let key, _):
        print("Missing key: \(key.stringValue)")
    case .typeMismatch(let type, let context):
        print("Type mismatch: expected \(type) at \(context.codingPath)")
    // ...
    }
}
```
→ See [decoding-errors.md](references/decoding-errors.md)

## Quick Fixes

| Symptom | Fix |
|---------|-----|
| "No such module" | Clean build folder (Cmd+Shift+K) |
| Simulator stuck | Reset simulator (Device → Erase All Content) |
| Network timeout | Check API URL, increase timeout |
| "Recording too short" | Add hardware settle time after playback |
| "Cannot connect to localhost" | Check backend running, ATS settings |

## Useful Commands

```bash
# Check if backend is running
curl http://localhost:8002/docs

# View simulator logs
xcrun simctl spawn booted log stream --predicate 'subsystem == "com.yourapp"'

# List simulators
xcrun simctl list devices
```
