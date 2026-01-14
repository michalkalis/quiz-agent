# Verify API Contract

Verify that iOS Codable structs match backend Pydantic models.

## Instructions

1. **Check Backend Models**: Read Pydantic models in:
   - `apps/quiz-agent/app/models/`
   - `packages/shared/quiz_shared/models/`

2. **Check iOS Models**: Read Swift Codable structs in:
   - `apps/ios-app/CarQuiz/CarQuiz/Models/`

3. **Compare**: For each model pair, verify:
   - Field names match (accounting for snake_case vs camelCase)
   - Field types are compatible (str↔String, int↔Int, Optional↔nil)
   - Required vs optional fields align

4. **Report**:
   - List any mismatches found
   - Suggest fixes if discrepancies exist
   - Confirm "API contract verified" if all matches

## Optional: Build Verification

If $ARGUMENTS contains "build", also run:
```bash
cd apps/ios-app/CarQuiz && xcodebuild -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```
