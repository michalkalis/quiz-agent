# Build Issue Troubleshooting

## Quick Fixes

### Clean Build
```bash
# Xcode menu
Product → Clean Build Folder (Cmd+Shift+K)

# Command line
xcodebuild clean -scheme Hangs-Local
```

### Delete DerivedData
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/

# Or specific project
rm -rf ~/Library/Developer/Xcode/DerivedData/Hangs-*
```

### Reset Package Cache
```
Xcode → File → Packages → Reset Package Caches
```

### Restart Xcode
Sometimes just quit and reopen Xcode.

## Common Errors

### "No such module 'ModuleName'"

**Causes:**
- Package not resolved
- Wrong target membership
- Cached build state

**Fixes:**
1. File → Packages → Resolve Package Versions
2. File → Packages → Reset Package Caches
3. Delete DerivedData
4. Verify package is in correct target

### "Cannot find type 'X' in scope"

**Causes:**
- Missing import
- File not in target
- Circular dependency

**Fixes:**
```swift
// Add missing import
import Foundation
import AVFoundation
import SwiftUI
```

Check file's Target Membership in File Inspector (right panel).

### "Ambiguous use of 'X'"

**Causes:**
- Name collision between modules
- Generic type inference failure

**Fixes:**
```swift
// Qualify with module name
let session = Foundation.URLSession.shared

// Add explicit type
let items: [MyModule.Item] = []
```

### "Command PhaseScriptExecution failed"

**Causes:**
- Build script error
- Missing file referenced in script
- Permission issues

**Fixes:**
1. Check Build Phases scripts
2. Verify script paths exist
3. Run script manually to see errors

### Swift Concurrency Errors

```
'async' call in a function that does not support concurrency
```

**Fix:** Mark function as `async` or wrap in `Task {}`:
```swift
// Make caller async
func loadData() async {
    await fetchData()
}

// Or use Task
func loadData() {
    Task {
        await fetchData()
    }
}
```

### MainActor Isolation Errors

```
Main actor-isolated property 'X' can not be mutated from a non-isolated context
```

**Fix:** Add `@MainActor` or use `await MainActor.run`:
```swift
@MainActor
final class ViewModel: ObservableObject { ... }

// Or
await MainActor.run {
    self.items = newItems
}
```

## Xcode Indexing Issues

### Symptoms
- Autocomplete not working
- "Jump to Definition" fails
- Red squiggles on valid code

### Fixes
1. Wait for indexing (status bar)
2. Restart Xcode
3. Delete DerivedData
4. Delete `~/Library/Caches/com.apple.dt.Xcode`

## Simulator Issues

### Reset Simulator
```bash
# Specific simulator
xcrun simctl erase "iPhone 17 Pro"

# All simulators
xcrun simctl erase all
```

### Simulator Not Booting
```bash
# Shutdown all
xcrun simctl shutdown all

# List available
xcrun simctl list devices

# Boot specific
xcrun simctl boot "iPhone 17 Pro"
```

## Code Signing

### "Signing requires a development team"

1. Xcode → Project → Signing & Capabilities
2. Select your Team
3. Let Xcode manage signing

### Provisioning Profile Issues

```bash
# Clear old profiles
rm -rf ~/Library/MobileDevice/Provisioning\ Profiles/*
```

## Memory/Disk Issues

### "Build folder is out of space"
```bash
# Check disk space
df -h

# Clear Xcode caches
rm -rf ~/Library/Developer/Xcode/DerivedData/
rm -rf ~/Library/Caches/com.apple.dt.Xcode/
```

### Build Running Slow
- Close other apps
- Check CPU usage (Activity Monitor)
- Consider increasing RAM if < 16GB

## Version Compatibility

### Check Swift Version
```bash
xcrun swift --version
```

### Check Xcode Version
```bash
xcodebuild -version
```

### Minimum iOS Version
Check in project settings: Target → General → Minimum Deployments
