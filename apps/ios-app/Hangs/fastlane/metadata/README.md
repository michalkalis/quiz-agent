# App Store metadata (DRAFT — founder review pending)

Draft listing copy for `deliver`. Upload with `bundle exec fastlane metadata`
(metadata only, no binary, no screenshots). Screenshots are NOT here yet —
capture them once the UI is final.

Deliberate choices to revisit at founder review:
- primary_category ENTERTAINMENT (not GAMES): keeps the CarPlay
  voice-companion pitch viable (#97 — games are excluded from CarPlay).
- No prices in the description (storefront currencies differ).
- Slovak copy uses informal "ty" matching the app UI (#130 wording review open).
- app_privacy_details.json = privacy nutrition labels (no tracking declared);
  upload via fastlane `upload_app_privacy_details_to_app_store`.
