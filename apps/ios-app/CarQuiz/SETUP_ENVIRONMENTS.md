# Environment Setup Guide

This guide will help you configure multiple environments (Local, Production) in Xcode using the xcconfig files that have been created.

## Overview

The environment configuration system consists of:
- **xcconfig files** (`Configuration/*.xcconfig`) - Define environment-specific settings
- **Build Configurations** - Debug-Local, Release-Local, Debug-Prod, Release-Prod
- **Schemes** - CarQuiz-Local, CarQuiz-Prod (each maps to a configuration)
- **Config.swift** - Reads values from Info.plist at runtime
- **Info.plist** - Contains placeholders that get replaced at build time

## Step 1: Add xcconfig Files to Xcode

1. Open `CarQuiz.xcodeproj` in Xcode
2. In the Project Navigator (left sidebar), right-click on the project root
3. Select **"Add Files to CarQuiz..."**
4. Navigate to the `Configuration` folder
5. Select all three xcconfig files:
   - `Shared.xcconfig`
   - `Local.xcconfig`
   - `Prod.xcconfig`
6. **Important:** Uncheck "Copy items if needed" (files are already in the right place)
7. Click **"Add"**

## Step 2: Create Build Configurations

1. In Xcode, select the **CarQuiz project** in the Project Navigator (blue icon at the top)
2. Select the **CarQuiz project** (not the target) in the editor area
3. Go to the **Info** tab
4. Under **Configurations**, you'll see Debug and Release

### Create Debug-Local Configuration:
1. Click the **"+"** button below the configurations list
2. Select **"Duplicate 'Debug' Configuration"**
3. Rename it to: `Debug-Local`

### Create Release-Local Configuration:
1. Click the **"+"** button again
2. Select **"Duplicate 'Release' Configuration"**
3. Rename it to: `Release-Local`

### Create Debug-Prod Configuration:
1. Click the **"+"** button again
2. Select **"Duplicate 'Debug' Configuration"**
3. Rename it to: `Debug-Prod`

### Create Release-Prod Configuration:
1. Click the **"+"** button again
2. Select **"Duplicate 'Release' Configuration"**
3. Rename it to: `Release-Prod`

You should now have 6 configurations:
- Debug (keep for backward compatibility)
- Release (keep for backward compatibility)
- Debug-Local
- Release-Local
- Debug-Prod
- Release-Prod

## Step 3: Assign xcconfig Files to Configurations

Still in the **Info** tab of the project settings:

1. For each configuration, expand the disclosure triangle
2. For the **CarQuiz** target (not the test targets), select the xcconfig file:
   - **Debug** → Select `None` (or Local.xcconfig if you want)
   - **Release** → Select `None` (or Prod.xcconfig if you want)
   - **Debug-Local** → Select `Local.xcconfig`
   - **Release-Local** → Select `Local.xcconfig`
   - **Debug-Prod** → Select `Prod.xcconfig`
   - **Release-Prod** → Select `Prod.xcconfig`

**Note:** Leave test target configurations set to "None" or they can inherit from the main target.

## Step 4: Verify Build Settings

1. Select the **CarQuiz target** (not the project)
2. Go to the **Build Settings** tab
3. Search for "Product Bundle Identifier"
4. You should see it's now set to `$(PRODUCT_BUNDLE_IDENTIFIER)` (inherited from xcconfig)
5. Search for "API_BASE_URL" - you should see it defined

## Step 5: Create Schemes

### Create CarQuiz-Local Scheme:
1. In Xcode, go to **Product → Scheme → Manage Schemes...**
2. Select the existing **CarQuiz** scheme
3. Click the **gear icon** at the bottom and select **"Duplicate"**
4. Rename it to: `CarQuiz-Local`
5. Check **"Shared"** (important for CI/CD and team collaboration!)
6. Click **"Close"**
7. With `CarQuiz-Local` selected, click **"Edit..."**
8. For each action (Run, Test, Profile, Analyze, Archive):
   - Expand the action in the left sidebar
   - Change **Build Configuration** to `Debug-Local` (for Run, Test, Analyze)
   - Change **Build Configuration** to `Release-Local` (for Archive)
9. Click **"Close"**

### Create CarQuiz-Prod Scheme:
1. Go to **Product → Scheme → Manage Schemes...**
2. Select the **CarQuiz-Local** scheme
3. Click the **gear icon** and select **"Duplicate"**
4. Rename it to: `CarQuiz-Prod`
5. Ensure **"Shared"** is checked
6. Click **"Edit..."**
7. For each action (Run, Test, Profile, Analyze, Archive):
   - Expand the action
   - Change **Build Configuration** to `Debug-Prod` (for Run, Test, Analyze)
   - Change **Build Configuration** to `Release-Prod` (for Archive)
8. Click **"Close"**

## Step 6: Verify Schemes Are Shared

1. In Finder, navigate to: `CarQuiz.xcodeproj/xcshareddata/xcschemes/`
2. You should see:
   - `CarQuiz-Local.xcscheme`
   - `CarQuiz-Prod.xcscheme`
3. These files will be committed to git, so your team and CI/CD can use them

## Step 7: Test the Setup

### Test Local Environment:
1. In Xcode, select **CarQuiz-Local** scheme from the scheme dropdown
2. Build and run (Cmd+R)
3. The app should connect to `http://localhost:8002`
4. Check the console logs to verify the environment

### Test Production Environment:
1. Select **CarQuiz-Prod** scheme
2. Build and run (Cmd+R)
3. The app should connect to `https://quiz-agent-api.fly.dev`
4. Verify in console logs

## For CI/CD

### Building from Command Line:

```bash
# Build Local environment
xcodebuild -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build

# Build Production environment
xcodebuild -scheme CarQuiz-Prod -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build

# Archive for App Store (Production)
xcodebuild -scheme CarQuiz-Prod archive -archivePath ./build/CarQuiz.xcarchive

# Run tests with Local environment
xcodebuild test -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Adding More Environments (Dev, Staging)

To add Dev and Staging later:

1. Create new xcconfig files:
   - `Configuration/Dev.xcconfig`
   - `Configuration/Staging.xcconfig`
2. Add them to Xcode project
3. Create new configurations:
   - Debug-Dev, Release-Dev
   - Debug-Staging, Release-Staging
4. Assign xcconfig files to configurations
5. Create new schemes:
   - CarQuiz-Dev
   - CarQuiz-Staging
6. Mark schemes as "Shared"

## Troubleshooting

### "API_BASE_URL not found in Info.plist"
- Verify xcconfig file is assigned to the active configuration
- Clean build folder (Cmd+Shift+K) and rebuild
- Check that Info.plist contains `$(API_BASE_URL)` placeholder

### xcconfig file not found
- Make sure you added the files to the Xcode project (not just in Finder)
- Verify the file reference is correct in the Project Navigator

### Scheme not available in CI/CD
- Ensure the scheme is marked as "Shared" in Manage Schemes
- Commit the `.xcscheme` files in `xcshareddata/xcschemes/` to git

### Build settings conflict
- Check for hardcoded values in Build Settings that override xcconfig
- Set conflicting settings to `$(inherited)` to use xcconfig values

## Summary

After completing these steps, you'll have:
- ✅ Multiple environment configurations (Local, Prod)
- ✅ Easy switching via Xcode scheme selector
- ✅ CI/CD-ready (shared schemes)
- ✅ No code changes needed to switch environments
- ✅ Type-safe configuration via Config.swift

Your development workflow:
1. Select **CarQuiz-Local** → Test against localhost
2. Select **CarQuiz-Prod** → Test against production API
3. No code changes required!
