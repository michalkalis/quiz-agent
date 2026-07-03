# UI/UX HIG Research — Hangs (voice-first driving trivia)

**Date:** 2026-07-03
**Purpose:** Outward-sourced, cited HIG research to back a UI/UX review of the Hangs iOS app. The quiz screen is judged driving-first (hands-free, eyes-off-road); Settings and Sign-in are judged as normal screens.
**Method:** Apple Human Interface Guidelines (HIG) + Apple API docs as primary sources; WCAG and behavioral-science literature as secondary. Every claim below carries a URL. Where the canonical `developer.apple.com` HIG page is a JS-rendered SPA, the same guidance was read via a faithful markdown mirror or an evergreen HIG mirror and is cited to the canonical Apple page it reproduces.

---

## 1. Back navigation (Settings screen)

**Context:** Settings has a custom back button in the top-RIGHT, edge-swipe-back doesn't work, and the whole header scrolls away.

### What Apple says

- The navigation bar **appears at the top of the screen** and enables moving through a hierarchy of screens. "A navigation bar appears at the top of an app screen, below the status bar, and enables navigation through a series of hierarchical app screens." — [Navigation bars, HIG](https://developer.apple.com/design/human-interface-guidelines/navigation-bars) (evergreen mirror: [codershigh HIG](https://codershigh.github.io/guidelines/ios/human-interface-guidelines/ui-bars/navigation-bars/index.html))
- The back button lives on the **left / leading side**: "When a new screen is displayed, a back button, often labeled with the title of the previous screen, appears on the left side of the bar." — [Navigation bars, HIG (mirror)](https://codershigh.github.io/guidelines/ios/human-interface-guidelines/ui-bars/navigation-bars/index.html)
- **Use the standard back button.** "People know that the standard back button lets them retrace their steps through a hierarchy of information." If you customize it, "make sure it still looks like a back button, behaves as people expect, matches the rest of your interface, and is consistently implemented." — [Navigation bars, HIG](https://developer.apple.com/design/human-interface-guidelines/navigation-bars)
- A navigation bar should contain "no more than the view's current title, a back button, and one control that manages the view's contents," and "the back button always performs a single action — returning to the previous screen." — [Navigation bars, HIG](https://developer.apple.com/design/human-interface-guidelines/navigation-bars)
- **Edge-swipe-back is a user expectation Apple documents.** "When performed with one finger, a swipe returns to the previous screen… To help accelerate this action, many apps also offer a shortcut gesture — such as swiping from the side of the display or window — while continuing to provide the back button." — [Gestures / Touchscreen gestures, HIG](https://developer.apple.com/design/human-interface-guidelines/gestures)
- **Don't override standard gestures.** "Avoid using standard gestures to perform nonstandard actions… People are familiar with the standard gestures and don't appreciate being forced to learn different ways to do the same thing." — [Gestures, HIG](https://developer.apple.com/design/human-interface-guidelines/gestures)
- Implementation note (why swipe broke): SwiftUI's `NavigationStack` sits on top of `UINavigationController`; **hiding the default back button to supply a custom one disables the interactive pop (edge-swipe) gesture** unless you re-enable it (`interactivePopGestureRecognizer.delegate = nil`). This is a well-known consequence of replacing the standard back button. — [Apple Developer Forums: Custom back button with SwiftUI](https://developer.apple.com/forums/thread/662510), [Keeping swipe-back with custom nav buttons](https://akashkottil.medium.com/how-to-keep-the-swipe-back-gesture-working-with-custom-navigation-buttons-in-swiftui-ed4b5cd8d2fd)

### Implication for Hangs
The Settings screen violates three standard patterns at once: back control on the **right** (HIG says leading/left), **broken edge-swipe** (the documented "retrace your steps" gesture), and a **header that scrolls away** (a standard nav bar stays pinned at the top). The fix is not a nicer custom button — it's to adopt the standard `NavigationStack` back button in the leading position, which restores edge-swipe and the pinned bar for free. If a custom look is truly required, it must still be leading-side, look/behave like Back, and re-enable the interactive pop gesture. This is the single highest-confidence, lowest-risk correction in the review.

---

## 2. Sign in with Apple

**Context:** where the sign-in lives, button styling, and the "name/email only arrive once" trap.

### Button style, size, placement (HIG)

- **Prominence:** "Prominently display a Sign in with Apple button." and "Make it no smaller than other sign-in buttons; don't make people scroll to see it." — [Sign in with Apple, HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- **Style must fit the background:** the **black** style is for white/light backgrounds with sufficient contrast, **white** for dark backgrounds, **white-with-outline** for light backgrounds that lack contrast with a white fill. "Don't use [black] on black or dark backgrounds." — [Sign in with Apple → Buttons, HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- **Size:** default and recommended button height in iOS is **44 pt**; title font size ≈ 43% of button height (button height ≈ 233% of the title font size); maintain the minimum size and the margin around the button. — [Sign in with Apple → Buttons, HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- **Corner radius** is customizable (square, default rounded, or capsule); "match corner radius to other buttons in your app." — [Sign in with Apple → Buttons, HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- **Title** must be one of the system-provided strings (Sign in / Sign up / Continue with Apple), preferably in the system font. — [Sign in with Apple → Buttons, HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)

### Dedicated screen vs. a Settings row

- Apple does **not** mandate a standalone sign-in screen. The HIG guidance is the opposite of forcing sign-in up front: **"Delay sign-in as long as possible,"** "Let people explore before requiring sign-in," and "Welcome people to their new account immediately after Sign in with Apple completes." — [Sign in with Apple, HIG](https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple)
- The respected, HIG-consistent patterns are therefore: (a) a **sign-in sheet presented on first need** (when the user hits something that requires an account), and (b) an **Account section in Settings** for managing the signed-in state afterward. Both satisfy "prominent, not buried, not requiring a scroll" as long as the button isn't demoted below unrelated rows.

### The fullName / email "arrives only once" behavior (Apple API docs)

- **`fullName` and `email` are returned only on the first authorization.** "Apple only shares user information such as the display name with apps the first time a user signs in… subsequent logins… only return a user identifier." — [ASAuthorizationAppleIDCredential, Apple docs](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential)
- **Apple's recommended handling: persist immediately.** "It is highly recommended that app developers should securely store the user's credential locally until an account is successfully created at their server." — [ASAuthorizationAppleIDCredential, Apple docs](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential); see also [Implementing User Authentication with Sign in with Apple, Apple docs](https://developer.apple.com/documentation/AuthenticationServices/implementing-user-authentication-with-sign-in-with-apple)
- The presence/absence of `fullName`/`email` in the callback is also how you distinguish a **first-time sign-up from a returning login**. — [ASAuthorizationAppleIDCredential, Apple docs](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential)

### Implication for Hangs
Burying "Sign in with Apple" as one more row inside Settings is defensible **only** if it's an account-management entry point, not the primary sign-in moment — and even then it must not be smaller than or scrolled below other controls. The clean, HIG-aligned model: don't gate the app, present a proper Sign-in sheet at first need with a correctly-styled 44 pt button (black on Hangs' light surfaces, white on dark), and keep an Account row in Settings for status. Critically, the backend/client must **capture and persist `fullName` + `email` on the very first authorization** — if Hangs discards them (or the first sign-in fails after Apple returns them), that user's name/email is gone permanently and only recoverable by the user revoking access in iOS Settings and re-authorizing. This is a correctness bug, not a polish item.

---

## 3. Audio / replay / mute controls (TTS-driven, eyes-free)

**Context:** the app speaks questions via TTS and is used while driving. What are the expected "repeat the question" and "mute voice" affordances?

### Playback controls (HIG)

- Prefer the **system's playback affordances**; build custom controls "only if you need commands the system doesn't support (e.g., custom skip increments, related content display)." — [Playing audio, HIG](https://developer.apple.com/design/human-interface-guidelines/playing-audio)
- **Respect external audio controls** (Control Center, headphones, CarPlay/Bluetooth) and "never redefine the meaning of standard audio controls." — [Playing audio, HIG](https://developer.apple.com/design/human-interface-guidelines/playing-audio)
- For mute/volume: "Adjust relative levels, not overall volume… system volume always governs final output"; use the system volume view (`MPVolumeView`) rather than a bespoke volume UI. — [Playing audio, HIG](https://developer.apple.com/design/human-interface-guidelines/playing-audio)
- Handle interruptions (calls, Siri, other media) and decide whether to auto-resume; interruptions are resumable (phone call) or nonresumable (new playlist). — [Playing audio, HIG](https://developer.apple.com/design/human-interface-guidelines/playing-audio)

### Eyes-free / driving design (CarPlay HIG — nearest Apple guidance for in-car use)

- **Never command the driver's attention.** "The best apps support brief interactions and never command the driver's attention. On-screen information is minimal, relevant, and requires little decision making." — [CarPlay, HIG](https://developer.apple.com/design/human-interface-guidelines/carplay)
- **Voice first.** "Voice interaction using Siri enables drivers to control many apps without taking their hands off the steering wheel or eyes off the road." — [CarPlay, HIG](https://developer.apple.com/design/human-interface-guidelines/carplay)
- **Prefer standard controls; limit content.** "Prefer standard controls… Limit controls and content to what's relevant in the car." Don't expose every feature. — [CarPlay, HIG](https://developer.apple.com/design/human-interface-guidelines/carplay)

### Tap targets & Dynamic Type (glanceable use)

- **Minimum hit target 44×44 pt.** "Minimum 44×44 pt… for easy selection regardless of input method." — [Buttons, HIG](https://developer.apple.com/design/human-interface-guidelines/buttons); Accessibility lists the iOS/iPadOS default control size as **44×44 pt**. — [Accessibility, HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- **Adopt Dynamic Type** so text scales with the user's setting (support enlargement to at least ~200%), and give controls enough padding. — [Accessibility, HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### Implication for Hangs
"Repeat the question" and "Mute voice" are the two core eyes-free affordances and should be treated as **primary, glanceable controls, not settings**: large (well beyond the 44 pt floor — driving contexts justify oversized targets), high-contrast, in a stable on-screen position so a driver can hit them by muscle memory without reading. Because Hangs isn't a CarPlay app, it can't lean on the CarPlay chrome, so it must self-provide these. Ideally both are also voice-triggerable (Hangs already uses SpeechAnalyzer commands) so the truly hands-free path never needs a tap. Mute should ride the system volume model, not a bespoke slider, and TTS must yield gracefully to call/Siri interruptions.

---

## 4. Streaks & "best score" — is it "kind of nonsense"?

**Founder's question:** are streak + best score noise for a casual car trivia app?

### Evidence that streaks work (when the activity is a habit)

- Duolingo frames the streak explicitly as **habit engineering via repetition-in-context**: "if you repeat an action often enough in the same context, the act of doing it will start to feel automatic." — [Duolingo: the habit-building research behind your streak](https://blog.duolingo.com/how-duolingo-streak-builds-habit/)
- The streak's power is **loss aversion** — losses feel ~2× as painful as equivalent gains — converting a fuzzy long-term goal into a concrete daily loss-prevention trigger; churn drops sharply once the streak passes ~7 days. — [The psychology behind Duolingo's streak](https://www.justanotherpm.com/blog/the-psychology-behind-duolingos-streak-feature)
- Streaks are heavily A/B-validated at Duolingo (600+ experiments on the streak alone; a streak wager gave a measured +14% day-14 retention). — [Duolingo: the habit-building research behind your streak](https://blog.duolingo.com/how-duolingo-streak-builds-habit/)
- **Forgiveness matters:** a University of Pennsylvania / UCLA study found that giving people a little "slack" toward a goal is *more* motivating than rigid rules — the basis for Streak Freezes. — [Duolingo: improving the streak](https://blog.duolingo.com/improving-the-streak/)

### Evidence that streaks backfire (the critique)

- Streaks can invert the goal: "users often view extending their streak as more important than engaging in the underlying activity," and gamification can "sap the intrinsic enjoyment of the underlying activity, turning it into something done mainly for the sake of a reward." — [The Decision Lab: Streak Creep](https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification)
- Breaking a streak is **demotivating** and can push users to abandon the product entirely (loss aversion cuts both ways). "Adding to a streak can feel powerful, but it's ultimately empty when you lose interest in the activity itself." — [The Decision Lab: Streak Creep](https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification)
- Documented adverse effects of gamification misuse include **apprehension/anxiety and self-recrimination/guilt**, harming well-being. — [Negative Effects of Gamification in Education Software (arXiv 2305.08346)](https://arxiv.org/pdf/2305.08346); [When Gamification Spoils Your Learning (arXiv 2203.16175)](https://arxiv.org/pdf/2203.16175)
- **Meaningless-metric risk:** a number that "reliably rises every time I use the app" while real progress is unmeasurable is engagement theater — and badges/metrics for trivial actions dilute meaning ("if a user cannot explain… what they did to earn a badge, the badge is meaningless"). — [The Decision Lab: Streak Creep](https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification)

### Verdict (position taken)
The founder's instinct is **directionally right for Hangs.** Daily streaks earn their keep for products whose value proposition *is* a daily habit (language learning, fitness, meditation). Hangs is casual, occasional, road-trip trivia — sessions are episodic and tied to *being in the car*, not to a daily cadence the user controls. A daily streak here mostly manufactures guilt on days the user simply isn't driving, i.e. it punishes the intended usage pattern; that's the "streak creep / meaningless metric" failure mode, not the Duolingo success case. **Recommendation:** drop the daily streak (or, if kept, make it "sessions/quizzes-in-a-row within a trip" or a lifetime cumulative count with generous freezes — never a punishing daily reset). **"Best score" is different and worth keeping**: it's a low-pressure, self-referential mastery signal with no daily obligation and no loss-aversion whip, and it directly reflects the actual activity. Keep best-score; retire or re-base the daily streak.

---

## 5. Timers, auto-advance, and dialogs

**Context:** result screen auto-advances after 7 s with a tiny "Stay here" link; the End Quiz dialog has one destructive button and no Cancel; the answer countdown keeps ticking while the user types and behind dialogs.

### Alerts (HIG)

- **A destructive alert must offer Cancel.** "Include a Cancel button when there's a destructive action… A Cancel button provides a clear, safe way to avoid a destructive action." Consider making Cancel the default so the destructive choice is deliberate. — [Alerts, HIG](https://developer.apple.com/design/human-interface-guidelines/alerts)
- Placement: default/most-likely action on the **trailing** side (top of a stack); **Cancel on the leading side / bottom of a stack**; always title it "Cancel." — [Alerts, HIG](https://developer.apple.com/design/human-interface-guidelines/alerts)
- **Use alerts sparingly** — "they interrupt the current task"; avoid purely informational alerts; don't alert at startup. — [Alerts, HIG](https://developer.apple.com/design/human-interface-guidelines/alerts)

### Time-limited interactions & auto-advance

- Apple accessibility guidance explicitly discourages timed dismissal: **"Avoid time-boxed UI — prefer explicit dismiss actions over auto-dismiss timers."** — [Accessibility, HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- WCAG (secondary source, the accepted standard for timing): for any time limit, users must be able to **turn off, adjust, or extend** it, with a warning at least 20 seconds before expiry and the ability to extend "at least ten times." Real-time/essential activities are the only exceptions. — [WCAG 2.1 SC 2.2.1 Timing Adjustable](https://www.w3.org/TR/WCAG21/#timing-adjustable)
- Auto-advancing after N seconds is only acceptable when it's clearly pauseable/dismissible and the escape hatch is obvious — the opposite of a "tiny link." A 7-second auto-advance with a small opt-out fails both the HIG "explicit dismiss" preference and WCAG's turn-off/extend requirement.

### Implication for Hangs
Three distinct fixes:
1. **End Quiz dialog** — add a "Cancel" (leading), keep the destructive "End quiz" trailing/red. A destructive alert with no cancel is a direct HIG violation and a real data-loss trap mid-quiz. Alternatively, since alerts should be rare, consider whether ending a quiz even warrants a modal alert vs. an undoable action.
2. **Result auto-advance** — 7 s with a tiny "Stay here" is the anti-pattern. Either remove auto-advance (explicit "Next" tap — the HIG-preferred "explicit dismiss"), or make the countdown obvious, pauseable, and give a large, high-contrast "Stay" control. For a driving context specifically, auto-advance can be *good* (no tap needed) — but then it needs a clearly visible timer and a big pause target, not a hidden link.
3. **Answer countdown** — a timer that keeps ticking while the user is typing an answer, and *behind modal dialogs*, is a fairness/stress bug. Pause the countdown whenever input is focused or a dialog is up; resume on dismiss. This aligns with "give people enough time" and avoids penalizing the user for the app's own interruptions.

---

## 6. Visual consistency

### Color (HIG)

- **One accent, applied to the primary action.** Don't spread colored backgrounds across many controls — "only the primary action." — [Color, HIG](https://developer.apple.com/design/human-interface-guidelines/color)
- **Use semantic/system colors and don't redefine them.** "Don't redefine the semantic meanings of dynamic system colors. Use them as intended"; don't hard-code system color values (use `Color`/`UIColor`). — [Color, HIG](https://developer.apple.com/design/human-interface-guidelines/color)
- **Don't rely on color alone** to convey state/interactivity; pair with text or shape (also an accessibility requirement — contrast ≥ 4.5:1 for text). — [Color, HIG](https://developer.apple.com/design/human-interface-guidelines/color), [Accessibility → Color and contrast, HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- **Use color consistently** — "avoid using the same color to mean different things." — [Color, HIG](https://developer.apple.com/design/human-interface-guidelines/color)

### Typography (HIG)

- **Use the built-in text styles** (Title/Headline/Body/…) to express hierarchy through size and weight, which also gives Dynamic Type for free. — [Typography, HIG](https://developer.apple.com/design/human-interface-guidelines/typography)
- **Minimize the number of typefaces** — "too many obscure hierarchy and hinder readability." — [Typography, HIG](https://developer.apple.com/design/human-interface-guidelines/typography)
- **Support Dynamic Type**; test with the largest accessibility sizes; keep the relative hierarchy at every size; iOS minimum legible size ~11 pt. — [Typography, HIG](https://developer.apple.com/design/human-interface-guidelines/typography)

### Dark / Light mode (HIG)

- **Support both appearances** and test in each (including Increase Contrast / Reduce Transparency). — [Dark Mode, HIG](https://developer.apple.com/design/human-interface-guidelines/dark-mode)
- **Use semantic/adaptive colors** that switch automatically; **don't ship an app-specific appearance toggle** — respect the systemwide choice. — [Dark Mode, HIG](https://developer.apple.com/design/human-interface-guidelines/dark-mode)

### Implication for Hangs
Audit for a **single accent color** used only on primary actions, with everything else on semantic system colors so light/dark "just works" and contrast stays accessible (important when glancing while driving). Replace any hard-coded hex and ad-hoc font sizes with system colors and system text styles so hierarchy is consistent and Dynamic Type scales. Confirm both light and dark render correctly (test both), and drop any in-app light/dark toggle in favor of the system setting. State (correct/incorrect answers, timer urgency) must never be color-only — pair it with an icon, label, or shape for color-blind users and glanceability.

---

## Source index (primary)

- Navigation bars — https://developer.apple.com/design/human-interface-guidelines/navigation-bars
- Gestures / Touchscreen gestures — https://developer.apple.com/design/human-interface-guidelines/gestures
- Sign in with Apple (incl. Buttons) — https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple
- ASAuthorizationAppleIDCredential — https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential
- Implementing User Authentication with Sign in with Apple — https://developer.apple.com/documentation/AuthenticationServices/implementing-user-authentication-with-sign-in-with-apple
- Playing audio — https://developer.apple.com/design/human-interface-guidelines/playing-audio
- CarPlay — https://developer.apple.com/design/human-interface-guidelines/carplay
- Accessibility — https://developer.apple.com/design/human-interface-guidelines/accessibility
- Buttons — https://developer.apple.com/design/human-interface-guidelines/buttons
- Alerts — https://developer.apple.com/design/human-interface-guidelines/alerts
- Color — https://developer.apple.com/design/human-interface-guidelines/color
- Typography — https://developer.apple.com/design/human-interface-guidelines/typography
- Dark Mode — https://developer.apple.com/design/human-interface-guidelines/dark-mode
- WCAG 2.1 SC 2.2.1 Timing Adjustable — https://www.w3.org/TR/WCAG21/#timing-adjustable

## Source index (secondary)

- Duolingo — habit research behind the streak — https://blog.duolingo.com/how-duolingo-streak-builds-habit/
- Duolingo — improving the streak (slack/Streak Freeze) — https://blog.duolingo.com/improving-the-streak/
- Psychology behind Duolingo's streak — https://www.justanotherpm.com/blog/the-psychology-behind-duolingos-streak-feature
- The Decision Lab — Streak Creep — https://thedecisionlab.com/insights/consumer-insights/streak-creep-the-perils-of-too-much-gamification
- Negative Effects of Gamification in Education Software (arXiv) — https://arxiv.org/pdf/2305.08346
- When Gamification Spoils Your Learning (arXiv) — https://arxiv.org/pdf/2203.16175
- SwiftUI custom back button breaks swipe-back — https://developer.apple.com/forums/thread/662510 · https://akashkottil.medium.com/how-to-keep-the-swipe-back-gesture-working-with-custom-navigation-buttons-in-swiftui-ed4b5cd8d2fd
