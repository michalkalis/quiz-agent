# Multi-Environment Configuration - Summary

## ✅ What's Been Set Up

Your iOS app now has a complete multi-environment configuration system!

### 1. Configuration Files Created
```
Configuration/
├── Shared.xcconfig       # Common settings for all environments
├── Local.xcconfig        # Local development (localhost:8002)
└── Prod.xcconfig         # Production (quiz-agent-api.fly.dev)
```

### 2. Build Configurations
- **Debug** & **Release** (original, kept for backward compatibility)
- **Debug-Local** & **Release-Local** (for local development)
- **Debug-Prod** & **Release-Prod** (for production)

### 3. Schemes (Shared)
- **Hangs** (original)
- **Hangs-Local** → Uses Debug-Local/Release-Local configs
- **Hangs-Prod** → Uses Debug-Prod/Release-Prod configs

Schemes are marked as "Shared" and committed to git for team collaboration and CI/CD.

### 4. Code Updates
- **Config.swift** - Now reads from Info.plist (populated by xcconfig at build time)
- **Info.plist** - Contains placeholders: `$(API_BASE_URL)`, `$(API_VERSION)`, `$(ENVIRONMENT_NAME)`

## 🎯 Final Step Required

You need to assign the xcconfig files to the build configurations in Xcode.

**See: [QUICK_SETUP.md](./QUICK_SETUP.md)** for 2-minute instructions.

## 🚀 Usage

### In Xcode
1. Select scheme from dropdown:
   - **Hangs-Local** → Test against localhost
   - **Hangs-Prod** → Test against production API
2. Hit Cmd+R to build and run

### From Command Line

**Build Local:**
```bash
xcodebuild -scheme Hangs-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

**Build Production:**
```bash
xcodebuild -scheme Hangs-Prod \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

**Run Tests (Local):**
```bash
xcodebuild test -scheme Hangs-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

**Archive for App Store (Production):**
```bash
xcodebuild archive -scheme Hangs-Prod \
  -archivePath ./build/Hangs.xcarchive
```

## 🌍 Environment Details

### Local Environment
- **API URL:** `http://localhost:8002`
- **Use Case:** Development, debugging, testing new features
- **Device:** Works on both Simulator and Physical Device
- **Requirement:** Backend must be running locally

### Production Environment
- **API URL:** `https://quiz-agent-api.fly.dev`
- **Use Case:** Testing against production, TestFlight builds, App Store releases
- **Device:** Works on both Simulator and Physical Device

## 📋 CI/CD Integration

### GitHub Actions Example

```yaml
name: iOS Build

on:
  push:
    branches: [main, develop]

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Build Local Environment
        run: |
          cd apps/ios-app/Hangs
          xcodebuild -scheme Hangs-Local \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
            clean build

      - name: Build Production Environment
        run: |
          cd apps/ios-app/Hangs
          xcodebuild -scheme Hangs-Prod \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
            clean build

      - name: Run Tests
        run: |
          cd apps/ios-app/Hangs
          xcodebuild test -scheme Hangs-Local \
            -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## 🔧 Adding More Environments

Want to add Dev, Staging, or other environments?

### 1. Create xcconfig file
```bash
cat > Configuration/Dev.xcconfig << 'EOF'
#include "Shared.xcconfig"

ENVIRONMENT_NAME = Development
API_BASE_URL = https://dev.quiz-agent-api.fly.dev
PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_BASE).dev
PRODUCT_NAME = $(APP_DISPLAY_NAME) Dev
EOF
```

### 2. Add to Xcode
- Right-click Configuration folder in Xcode
- Add Files to Hangs...
- Select Dev.xcconfig

### 3. Create Build Configurations
- Project Settings → Info tab
- Duplicate Debug → Rename to "Debug-Dev"
- Duplicate Release → Rename to "Release-Dev"
- Assign Dev.xcconfig to both

### 4. Create Scheme
- Product → Scheme → Manage Schemes
- Duplicate Hangs-Local
- Rename to "Hangs-Dev"
- Edit → Set build configurations to Debug-Dev/Release-Dev
- Mark as "Shared"

## 🐛 Troubleshooting

### Error: "API_BASE_URL not found in Info.plist"
**Cause:** xcconfig file not assigned to the active configuration

**Fix:**
1. Open Xcode → Project Settings → Info tab
2. Expand the configuration you're using
3. Select the correct xcconfig file for the Hangs target
4. Clean build (Cmd+Shift+K) and rebuild

### Schemes not showing in Xcode
**Fix:**
- Product → Scheme → Manage Schemes
- Check the boxes next to Hangs-Local and Hangs-Prod
- Ensure "Shared" is checked

### CI/CD can't find scheme
**Fix:**
- Ensure schemes are marked as "Shared" in Xcode
- Commit `Hangs.xcodeproj/xcshareddata/xcschemes/*.xcscheme` to git

### Build settings not applying
**Fix:**
- Check for hardcoded values in Build Settings that override xcconfig
- Set conflicting settings to `$(inherited)` to use xcconfig values
- Clean derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData/`

## 📚 Best Practices

### 1. Keep xcconfig files simple
- Only environment-specific values go in xcconfig files
- Common settings stay in Xcode project settings

### 2. Never commit secrets
- Add sensitive xcconfig files to .gitignore if needed
- Use CI/CD secret management for production keys

### 3. Use meaningful scheme names
- Scheme name should indicate environment clearly
- Format: `{AppName}-{Environment}` (e.g., Hangs-Staging)

### 4. Test before committing
- Build with each scheme before pushing changes
- Verify environment variables are loading correctly

### 5. Document environment-specific behavior
- Update this README when adding new environments
- Document any environment-specific configurations

## 🎓 How It Works

```
Build Time Flow:
┌─────────────┐
│Select Scheme│ (e.g., Hangs-Local)
└──────┬──────┘
       │
       ▼
┌────────────────┐
│Build Config    │ (e.g., Debug-Local)
│+ xcconfig file │ (Local.xcconfig)
└──────┬─────────┘
       │
       ▼
┌─────────────────┐
│Build Settings   │ API_BASE_URL=http://localhost:8002
│Merged & Resolved│ ENVIRONMENT_NAME=Local
└──────┬──────────┘
       │
       ▼
┌──────────────┐
│Info.plist    │ Placeholders replaced:
│Processing    │ $(API_BASE_URL) → http://localhost:8002
└──────┬───────┘
       │
       ▼
┌──────────────────┐
│Runtime           │
│Config.swift reads│ Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL")
│from Info.plist   │ Returns: "http://localhost:8002"
└──────────────────┘
```

## 📖 Additional Resources

- [Official Xcode Schemes Documentation](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project)
- [SETUP_ENVIRONMENTS.md](./SETUP_ENVIRONMENTS.md) - Detailed manual setup guide
- [QUICK_SETUP.md](./QUICK_SETUP.md) - Complete the final xcconfig assignment step

## 🎉 Benefits

✅ **No Code Changes** - Switch environments by selecting a scheme
✅ **Type-Safe** - Config.swift provides type-safe access to environment values
✅ **CI/CD Ready** - Explicit scheme selection in build commands
✅ **Team Collaboration** - Shared schemes committed to git
✅ **Scalable** - Easy to add dev, staging, or custom environments
✅ **Industry Standard** - Follows Apple and community best practices

---

**Questions?** See troubleshooting section or refer to the detailed setup guides.
