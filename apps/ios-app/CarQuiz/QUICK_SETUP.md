# Quick Environment Setup - Final Step

Almost done! Just one quick manual step to complete the environment setup.

## What's Already Done ✅

- ✅ xcconfig files created (`Configuration/*.xcconfig`)
- ✅ Build configurations created (Debug-Local, Release-Local, Debug-Prod, Release-Prod)
- ✅ Schemes created (CarQuiz-Local, CarQuiz-Prod)
- ✅ Config.swift updated to read from build settings
- ✅ Info.plist updated with placeholders

## Final Step (2 minutes) 🎯

### Assign xcconfig Files to Configurations

1. **Open Xcode**
   ```bash
   open CarQuiz.xcodeproj
   ```

2. **Select the Project** (not the target)
   - Click on the blue "CarQuiz" project icon in the Project Navigator (left sidebar)

3. **Go to Info Tab**
   - With the project selected, click the "Info" tab at the top

4. **Assign xcconfig Files**
   Under "Configurations", you'll see all 6 configurations. For each one, expand the disclosure triangle and assign the xcconfig file for the **CarQuiz target** (NOT the test targets):

   | Configuration | Assign to CarQuiz Target |
   |--------------|--------------------------|
   | Debug | `None` (or Local.xcconfig if you prefer) |
   | Release | `None` (or Prod.xcconfig if you prefer) |
   | **Debug-Local** | **Local.xcconfig** |
   | **Release-Local** | **Local.xcconfig** |
   | **Debug-Prod** | **Prod.xcconfig** |
   | **Release-Prod** | **Prod.xcconfig** |

   **How to assign:**
   - Click on the row under "CarQuiz" target
   - Select the xcconfig file from the dropdown

   ![Example](https://developer.apple.com/library/archive/featuredarticles/XcodeConcepts/Art/project_settings_2x.png)

5. **Save** (Cmd+S)

## Test It! 🚀

### Test Local Environment:
```bash
# Option 1: Build from Xcode
# Select "CarQuiz-Local" scheme from dropdown → Cmd+R

# Option 2: Build from command line
cd /Users/michalkalis/Library/CloudStorage/GoogleDrive-michal.kalis@gmail.com/My\ Drive/_projects/ai-developer-course/code/quiz-agent/apps/ios-app/CarQuiz
xcodebuild -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Expected: App connects to `http://localhost:8002`

### Test Production Environment:
```bash
# Select "CarQuiz-Prod" scheme from dropdown → Cmd+R

# Or from command line:
xcodebuild -scheme CarQuiz-Prod -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Expected: App connects to `https://quiz-agent-api.fly.dev`

## Verify Configuration

To verify the environment is loaded correctly, add a print statement in your app:

```swift
print("🌍 Environment: \(Config.environmentName)")
print("🔗 API URL: \(Config.apiBaseURL)")
```

You should see:
- **CarQuiz-Local**: Environment: Local, API URL: http://localhost:8002
- **CarQuiz-Prod**: Environment: Production, API URL: https://quiz-agent-api.fly.dev

## For CI/CD

Once set up, your CI/CD can build different environments:

```bash
# Build and test Local
xcodebuild test -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Archive Production for App Store
xcodebuild archive -scheme CarQuiz-Prod -archivePath ./build/CarQuiz.xcarchive
```

## Troubleshooting

### "API_BASE_URL not found in Info.plist"
- Make sure you assigned the xcconfig file to the configuration
- Clean build folder: Cmd+Shift+K
- Rebuild: Cmd+B

### Can't see the schemes?
- Go to Product → Scheme → Manage Schemes
- Make sure "CarQuiz-Local" and "CarQuiz-Prod" are checked and marked as "Shared"

### Build fails with xcconfig errors?
- Make sure the xcconfig files are added to the Xcode project (not just in Finder)
- Check that the file paths are correct in Project Navigator

## Next Steps

Want to add more environments (Dev, Staging)?

1. Create new xcconfig file: `Configuration/Dev.xcconfig`
2. Duplicate an existing configuration in Project Settings → Info tab
3. Assign the new xcconfig to the new configuration
4. Create a new scheme that uses the new configuration
5. Mark it as "Shared"

Done! 🎉

