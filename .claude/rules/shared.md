# Shared Development Standards

This file contains cross-cutting concerns that apply across all apps in the monorepo.

## Git Workflow

### Branch Naming
- Feature branches: `feature/short-description` (e.g., `feature/add-scoring`)
- Bug fixes: `fix/short-description` (e.g., `fix/session-timeout`)
- Chores: `chore/short-description` (e.g., `chore/update-deps`)
- Hotfixes: `hotfix/short-description` (production-critical fixes)

### Commit Message Convention

Follow Conventional Commits specification:

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style changes (formatting, no logic change)
- `refactor`: Code refactoring (no feature/bug change)
- `test`: Adding or updating tests
- `chore`: Build process, dependencies, tooling

**Examples:**
```
feat(ios): add voice recording with background audio support

fix(backend): prevent session timeout during audio transcription

docs(readme): add OpenAPI generator setup instructions

chore(deps): update openai package to 1.5.0
```

**Scopes:**
- `ios` - iOS app changes
- `backend` - Quiz agent backend
- `questions` - Question generator service
- `web` - Web UI (when implemented)
- `shared` - Shared Python packages
- `ci` - CI/CD workflow changes

### Pull Request Workflow

1. **Create Feature Branch**
   ```bash
   git checkout -b feature/your-feature
   ```

2. **Commit Changes** (following conventional commits)
   ```bash
   git add .
   git commit -m "feat(backend): add new endpoint"
   ```

3. **Push to Remote**
   ```bash
   git push -u origin feature/your-feature
   ```

4. **Create Pull Request**
   - Use PR template (to be created)
   - Link to related issues
   - Add description of changes
   - Tag reviewers (based on CODEOWNERS)

5. **CI/CD Checks**
   - Backend tests must pass
   - iOS build must succeed
   - Linting must pass
   - No merge conflicts

6. **Merge Strategy**
   - Prefer "Squash and Merge" for clean history
   - Use "Rebase and Merge" for preserving commit history when needed
   - Never force push to main branch

## API Contract Management

### Backend ↔ iOS/Web Communication

**OpenAPI as Source of Truth:**
1. Backend FastAPI generates OpenAPI spec automatically
2. iOS uses Swift OpenAPI Generator (build-time generation)
3. Web UI uses TypeScript generator (when implemented)

**When Making API Changes:**

**Backend Developer:**
1. Update Pydantic models in `apps/quiz-agent/` or `packages/shared/`
2. Verify OpenAPI spec updated: `curl http://localhost:8002/openapi.json`
3. Test endpoint manually
4. Commit changes with conventional commit message
5. Notify in PR that API contract changed

**iOS Developer:**
1. Pull latest backend changes
2. Regenerate Swift client (automatic on build with OpenAPI Generator)
3. Update views/viewmodels if response structure changed
4. Test against running backend
5. Commit iOS changes in same PR (atomic commit) OR separate PR with reference

**Best Practice:** Prefer atomic commits that update both backend and iOS in single PR to prevent breakage.

### Breaking Changes

**Semantic Versioning for APIs:**
- Major version (v2): Breaking changes (remove fields, change types)
- Minor version (v1.1): Add new fields (backward compatible)
- Patch version (v1.0.1): Bug fixes

**Process for Breaking Changes:**
1. Announce in team chat/issue
2. Add deprecation warnings first (if possible)
3. Version API endpoints (`/api/v2/...`)
4. Update all clients atomically
5. Remove old endpoint after grace period

## Testing Standards

### Backend Testing (Python)
- **Minimum Coverage:** 80% for new code
- **Test Organization:** Mirror app structure in `tests/` directory
- **Fixtures:** Use pytest fixtures for common test data
- **Mocking:** Mock OpenAI API calls (don't hit real API in tests)

```bash
# Run tests with coverage
pytest apps/quiz-agent/tests/ --cov=app --cov-report=html
```

### iOS Testing (Swift)
- **Unit Tests:** Test ViewModels with mocked services
- **UI Tests:** Test critical user flows
- **Integration Tests:** Test against local backend (optional)

```bash
# Run tests
xcodebuild test -scheme CarQuiz -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Integration Testing
- Test full stack: iOS → Backend → OpenAI (mocked)
- Use Docker Compose for local backend (future)
- Automated E2E tests (future, when critical)

## Code Review Guidelines

### For Reviewers
- Verify tests pass and coverage maintained
- Check for security issues (hardcoded keys, SQL injection, XSS)
- Ensure code follows style guidelines
- Verify API changes don't break clients
- Check for performance issues (N+1 queries, memory leaks)

### For Authors
- Self-review before requesting review
- Add comments explaining complex logic
- Include screenshots for UI changes
- Link to related issues/PRs
- Respond to review comments promptly

### Review Checklist
- [ ] Tests pass in CI
- [ ] Code coverage maintained or increased
- [ ] No hardcoded secrets or API keys
- [ ] API changes documented in PR description
- [ ] iOS builds successfully (if API changed)
- [ ] Commit messages follow conventional commits
- [ ] No console.log / print statements left in production code

## Documentation Standards

### README Files
- Each app has its own README.md
- Include: Purpose, Setup, Development, Testing, Deployment
- Keep root README.md as overview with links to app READMEs

### Code Comments
- Write self-documenting code (clear variable names)
- Add comments for non-obvious logic
- Avoid obvious comments: `// Increment counter` (bad)
- Explain "why", not "what": `// Use exponential backoff to avoid rate limits` (good)

### API Documentation
- FastAPI generates docs automatically at `/docs`
- Add descriptions to Pydantic models and endpoints
- Example responses in docstrings

## Environment Management

### Environment Files
```
.env.local          # Local development (not committed)
.env.example        # Template (committed)
.env.production     # Production secrets (not committed, use Fly.io secrets)
```

### Required Environment Variables
```bash
# Backend
OPENAI_API_KEY=sk-...

# iOS (Config.swift)
# No environment variables (hardcoded API URL)

# Future: Add environment switching in iOS
```

### Secrets Management
- **Never commit secrets to git**
- Use `.env.local` for local development
- Use Fly.io secrets for production: `fly secrets set OPENAI_API_KEY=...`
- iOS: No secrets (backend handles all API keys)

## Dependency Management

### Backend (Python)
- Use `uv` for dependency management
- Pin versions in `pyproject.toml`
- Update regularly: `uv pip list --outdated`

### iOS (Swift)
- Use Swift Package Manager (SPM)
- Pin versions in Package.swift or Xcode project
- Update via Xcode: File → Package Dependencies → Update to Latest

### Monorepo Dependencies
- Shared Python packages in `packages/shared/`
- Install in editable mode: `uv pip install -e packages/shared`

## Performance Considerations

### Backend
- Use async/await for I/O operations
- Implement caching for frequently accessed data (TTS audio)
- Monitor response times (add logging/metrics)
- Optimize database queries (use indexes)

### iOS
- Lazy load data (not needed for MVP)
- Cache audio files locally (future)
- Profile with Instruments for memory leaks
- Test on older devices (iPhone 12 minimum)

## Security Best Practices

### Backend
- Validate all user input (Pydantic models)
- Use HTTPS in production
- Implement rate limiting (future)
- Sanitize error messages (don't expose internal details)
- Regular dependency updates for security patches

### iOS
- Use HTTPS for all API calls
- Validate SSL certificates (default URLSession)
- No sensitive data in UserDefaults (only session ID, which is safe)
- Request minimum permissions (microphone only)

### Shared
- No secrets in git (use .gitignore)
- Code review for security issues
- Dependency scanning (Dependabot)
- Regular security updates

## Deployment

### Backend
- **Platform:** Fly.io
- **Command:** `fly deploy`
- **Monitoring:** Fly.io dashboard
- **Logs:** `fly logs`

### iOS
- **Platform:** App Store Connect
- **Build:** Xcode Archive → Upload to App Store
- **Testing:** TestFlight for beta
- **Release:** Manual review by Apple (7-14 days)

### Deployment Checklist
- [ ] Tests pass in CI
- [ ] Version numbers updated
- [ ] Changelog updated
- [ ] Environment variables set
- [ ] Database migrations run (if any)
- [ ] Monitoring configured
- [ ] Rollback plan documented

## Troubleshooting Common Issues

### "iOS app can't connect to backend"
1. Verify backend is running: `curl http://localhost:8002/docs`
2. Check Config.swift has correct URL
3. Check iOS simulator network permissions
4. Verify CORS configured correctly in backend

### "Backend tests failing"
1. Check OpenAI API key set: `echo $OPENAI_API_KEY`
2. Verify dependencies installed: `uv pip list`
3. Check Python version: `python --version` (should be 3.11+)
4. Clear pytest cache: `rm -rf .pytest_cache`

### "iOS build failing"
1. Clean build folder: Cmd+Shift+K in Xcode
2. Delete derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData/`
3. Verify Xcode version: 16+ required
4. Check simulator is running: `xcrun simctl list`

### "Git merge conflicts in generated files"
- OpenAPI spec: Regenerate from backend
- iOS generated code: Don't commit (should be in .gitignore)
- Dependencies: Use theirs, then reinstall

## Monitoring and Observability

### Logging Standards
- Use structured logging (JSON format)
- Include context: session_id, user_id, timestamp
- Log levels: DEBUG, INFO, WARNING, ERROR, CRITICAL
- Don't log sensitive data (API keys, passwords)

### Metrics (Future)
- Response times per endpoint
- Error rates
- Active sessions count
- Audio processing duration

### Alerts (Future)
- Error rate spikes
- API downtime
- High memory usage
- Slow response times (>2s)
