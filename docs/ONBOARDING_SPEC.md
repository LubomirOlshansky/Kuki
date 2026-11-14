# Kūki first-run onboarding: implementation spec

Status: ready to implement · Version 1 (`onboardingVersion = 1`) · Written 2026-11-14
Implementer: read §0 first, then build in the order of §12. Do not invent copy: every string the
user sees is in this document. Strings are English only for now; put them in the String Catalog.

---

## 0. Summary

Ten short screens (nine on the demo path), about 90 seconds end to end. Any screen except the
permission primer can be skipped.

| # | Screen | Kanji | What happens | Skip? |
|---|--------|-------|--------------|-------|
| 1 | Welcome | 空気 | The ensō paints itself (the splash) | Skip |
| 2 | First, two questions | 問 | Quiz Q1 (goals) and Q2 (airing habit) | Skip |
| 3 | Breath | 息 | Science: indoor CO₂ is breathed air. Breath particles fill a room | Skip |
| 4 | Night | 寝 | Science and **interactive**: guess, then use the bedroom simulator and open the window | Skip |
| 5 | The line | 線 | Science and **interactive**: the ppm dial (ensō and pigment react). 1000 ppm is a signal, not a danger line | Skip |
| 6 | How Kūki listens | 聴 | Sensor → Apple Home → Kūki. The ensō, rooms and the chime. Honest recording note. Fork: Connect or Demo | Skip |
| 7 | Apple Home | 家 | Primer → system prompt → live detection (searching, found, several, none, denied, slow) | Skip, except on the primer |
| 8 | Where is it? | 所 | Quiz Q3: the first place | Skip |
| 9 | The fūrin | 鈴 | Quiz Q4 (CO₂ limit) and Q5 (chime and notification, notification asked in context) | Skip |
| 10 | Your plan | 始 | A summary built from the answers. Mac: Open at Login. **Begin** | – |

The demo path ("No sensor yet? Try the demo" on screen 6, or "Try the demo" on any
Apple Home failure state) skips screen 7, so the progress bar shows 9.

**Skip means "finish the introduction now".** It commits only the answers already given
(§6.4), sets `hasCompletedOnboarding`, and lands in the app. It is never a jump to another
onboarding screen. This keeps App Review's path to the app at one tap (§10.5).

---

## 1. Research

### 1.1 CO₂ science: claims the app shows

Rules for every claim:
- One short, plain sentence, with its source.
- Hedged where the science is mixed.
- No medical claims (App Store Review Guideline 1.4.1).
- Kūki shows what a sensor measures. **It is not a medical device**, and every Sources
  disclosure says so.
- Never write "healthy", "harmful", "toxic", "dangerous", "prevents", "illness" or
  "disease" in UI copy.

| ID | Claim exactly as shown in the UI | Source | Conditions and notes for the implementer |
|----|----------------------------------|--------|------------------------------------------|
| S1 | "Outside, air holds about 430 ppm of CO₂." | NOAA Global Monitoring Laboratory, *Trends in Atmospheric CO₂* (gml.noaa.gov/ccgg/trends) | Mauna Loa's May 2025 monthly mean was 430.5 ppm, the first seasonal peak above 430. The May 2026 peak was 432.3. The global mean rises about 2–3 ppm a year. Use 430 as the model baseline (`BedroomModel.outdoor`). `AirLevel.swift`'s comment still says "~420"; update it in the same change. |
| S2 | "Every breath out holds around 40,000 ppm, nearly a hundred times more." | Rudnick & Milton 2003, *Indoor Air* 13(3):237–245, doi:10.1034/j.1600-0668.2003.00189.x | The paper says exhaled breath holds "almost 40,000 p.p.m.". For the CO₂ added by breathing it derives Cₐ = 0.038 (38,000 ppm), from about 0.30 L/min CO₂ at 8.0 L/min ventilation. |
| S3 | "At 1000 ppm indoors, roughly 1.5% of each breath was recently breathed out by someone in the room." | Rudnick & Milton 2003 (rebreathed fraction f = (C − C₀) / Cₐ) | (1000 − 430) / 38,000 = 1.5%. At 1400 ppm it is 2.6%, at 2000 ppm 4.1%. Show this as "roughly". Rudnick & Milton's purpose was estimating airborne infection risk; say that **only in the Sources text**, as context, never as a promise (S3-note). |
| S3-note (Sources only) | "This method is used to estimate how much exhaled air people share in a room, for example in airborne-infection research. Kūki doesn't measure germs." | Rudnick & Milton 2003 | Keeps the infection link factual, not a health claim. |
| S4 | "With two people asleep and the window shut, a bedroom can pass 1000 ppm in under an hour." | **Kūki estimate**: single-zone mass balance (§8.1) with a 30 m³ room, 0.5 air changes an hour (Bekö et al. 2010, below) and 0.0035 L/s of CO₂ per sleeping adult (Persily & de Jonge 2017, *Indoor Air* 27(5):868–879, doi:10.1111/ina.12383) | The model gives 50 minutes for two sleepers, 31 for three and 136 for one. After 8 hours two sleepers reach about 2080 ppm. The UI labels this "Estimate". Verify the 0.0035 L/s value against Persily & de Jonge's table (adult at about 1 met); any value from 0.003 to 0.004 keeps the claim true. |
| S5 | "In one study, student bedrooms averaged 2585 ppm with the window shut and 660 ppm with it open." | Strøm-Tejsen, Zukowska, Wargocki & Wyon 2016, *Indoor Air* 26(5):679–686, doi:10.1111/ina.12254 | This is the pilot: 14 subjects in single-occupancy dorm rooms, ventilation changed by opening a window. |
| S6 | "When the window was open, they slept better and felt less sleepy the next day." | Strøm-Tejsen et al. 2016 | Sleep was measured objectively with actigraphs. The study also improved next-day reported sleepiness, ability to concentrate, and a logical-thinking test. It is small; the screen says "Small studies, but they point the same way." |
| S7 | "In a sleep lab, nights at 1000 ppm or more brought slightly less efficient sleep than nights at 750 ppm." | Kang et al. 2024, *Building and Environment*, "Ventilation causing an average CO₂ concentration of 1,000 ppm negatively affects sleep: a field-lab study on healthy young people" (DTU Orbit record) | 36 young, healthy adults, two nights at each of 750, 1000 and 1300 ppm. Sleep efficiency fell 1.3% and 1.8%, and deep sleep fell at 1300 ppm. **Fill in the DOI before shipping** (PII S0360132323011459). "Slightly" is deliberate. |
| S8 | "Nearly a quarter of 500 Danish children's bedrooms passed 2000 ppm for at least 20 minutes a night." | Bekö et al. 2010, *Building and Environment* 45(10):2289–2295, doi:10.1016/j.buildenv.2010.04.014 | The figure is 23%. The geometric-mean air change rate was 0.46 h⁻¹, and 57% of rooms were below the Danish minimum of 0.5 h⁻¹. This is what justifies the model's 0.5 h⁻¹. |
| S9 | "Germany's Umweltbundesamt calls indoor air under 1000 ppm harmless, 1000–2000 ppm conspicuous, and over 2000 ppm unacceptable." | Umweltbundesamt / Ad-hoc-Arbeitsgruppe Innenraumrichtwerte 2008, "Gesundheitliche Bewertung von Kohlendioxid in der Innenraumluft", *Bundesgesundheitsblatt* 51:1358–1369 | The German terms are *hygienisch unbedenklich*, *auffällig* and *inakzeptabel*. "Conspicuous" is the standard translation of *auffällig*; keep it in quotes in the UI. |
| S10 | "ASHRAE treats CO₂ as a sign of how well a room is ventilated, not as a health limit." | ASHRAE Position Document on Indoor Carbon Dioxide (approved Feb 2022, revised Feb 2025); ASHRAE Technical FAQ 35; Interpretation IC 62-1999-03 | ASHRAE says 1000 ppm came from an odour-comfort criterion and is informational, "neither a ceiling nor a time-weighted average". |
| S11 | "Some lab studies found slower decision-making at 1000–1400 ppm." | Satish et al. 2012, *Environ. Health Perspect.* 120(12):1671–1677, doi:10.1289/ehp.1104789; Allen et al. 2016, *EHP* 124(6):805–812, doi:10.1289/ehp.1510037 | **Satish:** 22 participants, 2.5 h sessions at 600, 1000 and 2500 ppm. Six of nine decision-making scales fell at 1000 ppm and seven at 2500 ppm; the authors asked for replication. **Allen:** 24 office workers over six days at about 550, 945 and 1400 ppm. Scores fell as CO₂ rose (news coverage quoting the paper gives about 15% lower at ~945 ppm and 50% lower at ~1400 ppm; verify against the paper before quoting numbers). The UI does **not** show percentages. |
| S12 | "Others added pure CO₂ and saw no change, so it may be the rest of stale air, not CO₂ alone." | Zhang, Wargocki, Lian & Thyregod 2017, *Indoor Air* 27(1):47–64, doi:10.1111/ina.12284; Du, Tandoc, Mack & Siegel 2020, *Indoor Air* 30(6):1067–1082, doi:10.1111/ina.12706 | **Zhang:** 25 subjects, 255 min, pure CO₂ at 1000 and 3000 ppm, with no significant effect on cognition. Bioeffluents (breathed air) at 3000 ppm did affect some measures (companion paper, doi:10.1111/ina.12286). **Du:** a review of 37 studies; findings are "inconsistent". |
| S13 | "Open windows wide for a few minutes: about 3–5 in winter, 10–20 in summer." | Umweltbundesamt, "Richtig Lüften in Schulen" and "Freie Lüftung (Luftaustausch über Fenster)" (umweltbundesamt.de) | Duration depends on the difference between indoor and outdoor temperature. |
| S14 | "A window tilted all day airs less and costs more heat than a few wide-open minutes." | Umweltbundesamt, same pages | UBA: *Stoßlüften* is more effective and more energy-efficient than permanent tilting in the cold season. |
| S15 | "Opening windows on opposite sides clears a room fastest." | Umweltbundesamt (*Querlüften*) | |
| S16 | "Air your rooms several times a day, and the bedroom after you get up." | Umweltbundesamt, "Wie lüfte ich richtig?" (home ventilation and mould advice) | Several secondary sources give "2–3 times daily, about 5 min" in winter. The UI says "several times a day" and does not give a number. |
| S17 | "Europe's indoor-climate standard sets bedrooms' normal level at about 550 ppm above outdoor air, and its best level at about 380 above." | EN 16798-1:2019, Annex B example values, as reproduced in the REHVA Journal | Against 430 outdoors that is about 980 ppm (Category II) and 810 ppm (Category I). This underpins the 800 ppm "sensitive" limit choice. The Annex values are informative, and the standard is under revision. |
| S18 | "Sleep researchers suggest keeping bedrooms at or below 800 ppm." | Fan et al. 2023, *Science of the Total Environment* (PMID 37142023) | A single-blind field study of 35 people. Deep sleep was shorter at the lower ventilation rate in the 23 bedrooms with a clear CO₂ difference. Its introduction proposes ≤800 ppm (about ≥10 L/s per person). Used only as Sources context for the 800 ppm choice. |
| S19 | "REHVA's pandemic guidance used 800 ppm as an amber light and 1000 ppm as red." | REHVA COVID-19 guidance document (v2+, 2020–21) | Context for the 800 ppm choice. Sources only. |

**The five strongest facts** (they lead the screens):
1. S2 and S3: indoor CO₂ is breathed air, and at 1000 ppm about 1.5% of each breath is someone's exhale.
2. S5: closed-window bedrooms averaged 2585 ppm, against 660 ppm with the window open.
3. S8: 23% of 500 children's bedrooms passed 2000 ppm for 20+ minutes a night.
4. S9 with S10: the UBA bands, and ASHRAE's position that 1000 ppm is a ventilation signal, not a health limit.
5. S13 and S14: a few wide-open minutes (3–5 in winter, 10–20 in summer) beat a tilted window.

**What we deliberately do not claim:**
- No percentages for cognitive decline.
- No "CO₂ makes you ill".
- No infection-risk numbers.
- No claim that Kūki improves sleep.

**Existing copy to fix in the same change:** `CO2Level.poor.advice` reads "Ventilate now — focus
and sleep suffer." That states mixed evidence as fact. Change it to
"Ventilate now — open a window wide." (Open Question Q4.)

### 1.2 Onboarding best practice, distilled into rules

Sources:
- Apple HIG files in `/Users/mac/.claude/skills/apple-design/references/hig/`, cited as *file › heading*.
- Duolingo's growth lead in First Round Review ("The Tenets of A/B Testing from Duolingo's Master Growth Hacker"): moving sign-up back a few steps gave about +20% DAU.
- Irrational Labs' Headspace case study (an in-flow quiz).
- Teardowns of Calm and Headspace on screensdesign.com, Appcues GoodUX and Lazyweb:
  - Calm asks a multi-select goal question first, in a 4–6 question quiz.
  - Headspace reportedly trimmed its quiz to 3 questions after drop-off.
  - In a sample of 119 quiz apps, goal questions are the most common type.
- Permission-priming evidence:
  - Vendor data (Adjust, Plotline, AdExchanger) claims 2–3× opt-in.
  - A 950-person academic ATT study (ETAA'21 tech report) found that priming *reduced* opt-in.
  - The honest reading: priming helps when it explains a real need, not as a nudge.
- Learning science:
  - Richland, Kornell & Kao 2009, *J. Exp. Psychol.: Applied* 15(3):243–257, the pretesting effect (guessing first improves retention, even when the guess is wrong).
  - Kivetz, Urminsky & Zheng 2006, *J. Marketing Research* 43(1):39–58, the goal-gradient effect (progress you can see speeds completion).
- HomeKit and Matter apps:
  - Controller for HomeKit's support pages: a welcome screen with a single "Grant HomeKit Access" button before the system prompt.
  - Eve's Matter guide (evehome.com/meet-matter, MacRumors review): pairing happens in Apple's Home app flow by scanning the code, and Eve guides you back.
  - Apple support HT213441, "Pair and manage your Matter accessories": Home › + › Add Accessory › scan. Thread accessories need a Thread-enabled home hub (HomePod mini, HomePod 2nd gen, Apple TV 4K) or a compatible border router.
  - Apple Community threads: the Apple TV 4K 3rd gen *Wi-Fi-only* model (A2737) has no Thread. The Wi-Fi + Ethernet model (A2843) has it.
  - Troubleshooting guides (matteralpha, trunetto) list a missing border router as the top cause of failed pairing.
  - Apple's `HMAccessorySetupManager` documentation: `performAccessorySetup(using:)` hands setup to Apple Home. It is iOS 15.4+, and Apple's page lists Mac Catalyst only from 27.0.

| Rule | What we do | Source |
|------|------------|--------|
| R1 Teach through interaction | Screen 4's simulator and screen 5's dial are the core of the science; the user *does* the airing. | onboarding.md › Best practices ("Teach through interactivity") |
| R2 Brief, nothing to memorise | One striking fact leads each science screen; at most 3 short paragraphs; details go in Sources. | onboarding.md › Best practices |
| R3 Optional, findable later | Skip on every screen (except the primer); "Replay introduction" in Settings; never shown again after Skip. | onboarding.md › Best practices ("consider making it optional") |
| R4 Postpone non-essential setup; reasonable defaults | Every quiz question is preselected with a sensible default. Continue always works and Skip never writes unasked values. | onboarding.md › Additional requests |
| R5 Put required permissions in onboarding | HomeKit is required, so it is requested in the flow after explaining why. Notifications are *not* required, so they are asked only when the user turns the toggle on (screen 9). | onboarding.md › Additional requests; privacy.md › Requesting permission |
| R6 The primer has one button, "Continue", which opens the alert | No Skip, no Back, no "Allow" on screen 7's primer. The demo choice lives on screen 6, *before* the primer. | privacy.md › Pre-alert screens, windows, or views |
| R7 Splash only at the start of onboarding, briefly | Screen 1's ensō paints in ≤2.2 s, never auto-advances, and Begin is tappable at once. | launching.md › Best practices; onboarding.md › Additional content |
| R8 Restore state | The flow resumes at the last screen after a relaunch (§9.6). | launching.md › Best practices ("Restore the previous state…") |
| R9 No time-boxed UI | Nothing auto-advances. The Apple Home timeouts change the *message*, never dismiss it. | accessibility.md › Cognitive |
| R10 Reduce Motion: fades instead of x/y moves and blurs | Every animation has a static or opacity-only fallback (§7). `inkDiffuse`'s blur becomes plain opacity. | accessibility.md › Cognitive |
| R11 Never colour alone; 200% text; contrast | Each pigment always comes with its kanji and level title. Layouts reflow at accessibility sizes (§9). | accessibility.md › Vision |
| R12 Short quiz, every answer visibly used | Five questions spread over three screens, and each one changes a real setting or behaviour (§6). Screen 10 reflects the answers back. | Calm/Headspace teardowns; Duolingo (value before asks) |
| R13 Show progress | Brush-stroke progress dashes, plus "Step n of N" for VoiceOver. | Goal-gradient (Kivetz et al. 2006) |
| R14 Guess before the reveal | Screen 4 asks for a guess first. The guess is never graded harshly: "Most people guess lower." | Pretesting effect (Richland et al. 2009) |
| R15 Delegate pairing to Apple; detect additions automatically | No home-grown pairing. Offer Apple's Add Accessory sheet or the Home app, then react to `HMHomeDelegate.home(_:didAdd:)` with no Check-again tap needed. Explain the hub requirement up front, because it is the top failure cause. | Eve, Controller, Apple HT213441, troubleshooting guides |
| R16 Prime honestly | The primer states exactly what is read and that readings stay on the user's devices. No dark patterns. | ETAA'21 study; privacy.md › Best practices ("Be transparent…") |
| R17 iPhone Duo: respect safe areas and reserved regions | The Skip button lives inside the safe area (the outer display's 84 pt **trailing** inset). If the inner display is partly folded, keep content off the fold. | designing-for-iphone-duo.md › Best practices, › Reserved regions |

---

## 2. Visual language: use only what exists

- **Colours** (`Shared/Theme.swift`, `Ink`):
  - `paper` (background), `paperRaised` (cards and selected rows), `ink`, `inkSoft` (secondary text), `inkFaint` (decoration only), `hairline`.
  - The pigments `matcha` (clear), `kincha` (stale) and `shu` (act now, and the limit line).
  - `ai` (indigo, text buttons and links only).
  - **No new colours.** Places must never wear pigments.
  - **The level colour sequence is matcha → ink → kincha → shu** (`CO2Level.color`: *fine* is ink). Animations follow that order; never blend two pigments into a new hue. A crossfade between two layers is allowed.
- **Type** (`Typeface`):
  - `pageTitle(bold:)` for screen titles.
  - `title` for state titles and sensor names.
  - `body` for paragraphs.
  - `label` via `.kukiLabel()` for eyebrows, Sources and the progress caption.
  - `mincho(_:)` for kanji accents. Kanji are always `accessibilityHidden(true)`, as in `PageTitle`.
  - `numeral(_:bold:)` for big ppm readings, sized with `@ScaledMetric(relativeTo: .largeTitle)` and clamped as in `HeroReading`.
- **Components to reuse:**
  - `EnsoRing`, `AirMotes`, `InkDiffuse` / `.inkDiffuse`, `QuietButtonStyle`, `Hairline`, `PageTitle`.
  - `EmptySensorView.homeAccessMessage` and the text-button style.
  - `CO2Level` (kanji, title, advice, colour) and `Metric.co2.format` / `.spoken`.
- **Spacing:** there is no `Spacing` type. Add a file-private `enum OnboardingMetrics` in `Kuki/Onboarding/` that mirrors NowView's numbers, so it introduces no new design tokens:
  - `side`: 28 narrow, 48 wide.
  - `stack`: 22 (blocks), 8 (title to body), 18 (body to control).
  - `maxColumn`: 520.
  - `wideBreakpoint`: 760.
  - `maxWide`: 1040.
- **Buttons:**
  - *Primary:* `Text` in `Typeface.body.weight(.semibold)`, `Ink.paper` on a `Capsule().fill(Ink.ink)`, min height 50, max width 360, full width up to that, `QuietButtonStyle`. One per screen, pinned at the bottom with `.safeAreaInset(edge: .bottom)`.
  - *Secondary:* the indigo text button from `EmptySensorView.textButton` (`.subheadline`, `Ink.ai`, 44 pt min).
  - *Destructive:* none in onboarding.
- **Choice rows (quiz):**
  - Full-width, min height 56, corner radius 14.
  - Unselected: `Ink.paper` fill with a 0.5 pt `Ink.hairline` border.
  - Selected: `Ink.paperRaised` fill, a 1.5 pt `Ink.ink` border and a trailing `checkmark` SF Symbol in `Ink.ink`. The state is never shown by colour alone.
  - Leading kanji column (mincho 22, `inkSoft`), title (`body`), optional subtitle (`.subheadline`, `inkSoft`).
  - Press feedback: `QuietButtonStyle`.
  - `.accessibilityAddTraits(.isSelected)` when selected.
- **No ripple or flash.** Press feedback is the existing quiet sink.

---

## 3. Shell: container, progress, navigation

### 3.1 Layout (every screen)

```
┌ safe area ───────────────────────────────────────────┐
│ ‹ Back            ▬ ▬ ▬ ▭ ▭ ▭ ▭ ▭ ▭ ▭         Skip     │  top bar, 44 pt tall
│                                                      │
│   [kanji eyebrow · LABEL]                            │  ScrollView content,
│   Title                                              │  centred column,
│   illustration / interactive                         │  max width 520
│   body                                               │
│   ▸ Sources                                          │
│                                                      │
│ ┌──────────────── Continue ────────────────┐         │  bottom bar, pinned
│   secondary text button (optional)                   │  (.safeAreaInset)
└──────────────────────────────────────────────────────┘
```

**Top bar** (`OnboardingTopBar`, an `HStack` inside the safe area; never `ignoresSafeArea`):
- **Back:** a `chevron.backward` SF Symbol plus the text "Back".
  - Hidden on screen 1, on the primer state of screen 7, and while screen 7 is waiting for the system prompt.
- **Progress:**
  - N dashes, each a `Capsule` 3 pt tall, 6 pt gaps, total width ≤ 200 pt, centred.
  - Done dashes: `Ink.ink`. The current dash draws in with `trim(from: 0, to: 1)`, 0.45 s. Future dashes: `Ink.hairline`.
  - Hidden at accessibility text sizes; replaced by the caption "3 of 10" (kukiLabel).
  - `accessibilityElement`, label "Step 3 of 10".
- **Skip:** a text button "Skip" (`.subheadline`, `Ink.inkSoft`, 44×44 min).
  - Hidden on the primer and while the system prompt is up.
  - In replay mode the label is "Close" (§10.3).
  - **iPhone Duo outer display:** the Skip button must sit inside the 84 pt trailing safe inset's *safe* side. Put it in the top bar `HStack`, which respects safe areas automatically. Do not overlay it with `.ignoresSafeArea`. A known trap in this codebase family: top-right controls slid under that status column.

**Content:**
- A `ScrollView` with `.scrollBounceBehavior(.basedOnSize)`.
- Content column `frame(maxWidth: 520)`, centred.
- At width ≥ 760 the science screens (3–5) switch to two columns: illustration left, text right, max 1040, `spacing: 56`. This mirrors NowView's `AnyLayout` switch.
- If the content is shorter than the viewport, centre it vertically (`frame(minHeight: viewport)`, as NowView does).

**Bottom bar:** the primary button plus at most one secondary text button, on a `Ink.paper` background with a top `Hairline` that appears only when content scrolls under it (`onScrollGeometryChange`).

### 3.2 Navigation

- A custom step container (`OnboardingFlow`), **not** a `TabView` page style, so swipes can't bypass the primer.
- iPhone and iPad: an edge-swipe from the leading edge goes Back where Back is visible.
- Mac:
  - Return = primary.
  - ⌘[ = Back.
  - Esc = Skip. Esc does nothing on the primer.
- Forward and back transitions: §7.10.

### 3.3 Steps and paths

```swift
enum OnboardingStep: String, CaseIterable, Codable {
    case welcome, questions, breath, night, line, listen, appleHome, place, furin, plan
}
```

- Full path: all 10.
- Demo path: `appleHome` removed.
- The progress bar's N and n come from the current path:
  - `OnboardingPath.steps(demo: Bool) -> [OnboardingStep]`.
  - `OnboardingPath.index(of:demo:)`.

---

## 4. Screens and exact copy

Notation:
- **Eyebrow** = kanji in mincho 22 (`inkSoft`, hidden from VoiceOver) followed by a kukiLabel word.
- **Title** = `Typeface.pageTitle(bold:)`, with `.accessibilityAddTraits(.isHeader)`.
- **Body** = `Typeface.body`, `Ink.inkSoft` unless marked *ink*.

### Screen 1: Welcome (`welcome`)

- **Illustration:** the brush ensō paints itself (§7.1). Size `min(260, width × 0.6)`, `lineWidth 12`, `Ink.ink`, fraction 0.86. "空気" in mincho 40 (`inkSoft`) sits centred inside the ring.
- **Title:** "Kūki"
- **Subtitle** (`Typeface.title`, *ink*): "How fresh is the air in this room?"
- **Body:** "A few minutes on why air matters, then we'll find your sensor."
- **Primary:** "Begin"
- **Top bar:** progress, Skip. No Back.
- **VoiceOver:** the ensō is hidden. The title and subtitle are combined: "Kūki. How fresh is the air in this room?"

### Screen 2: First, two questions (`questions`), quiz Q1 and Q2

- **Eyebrow:** 問 · QUESTIONS
- **Title:** "First, two questions"

**Q1** (multi-select, any number):
- Heading (`Typeface.title`, *ink*): "What would you like fresher air for?"
- Hint (kukiLabel): "CHOOSE ANY"

| Kanji | Title | Subtitle | Value |
|-------|-------|----------|-------|
| 眠 | Sleep | Fresher air at night | `AirGoal.sleep` |
| 集 | Focus | Long days at a desk | `.focus` |
| 爽 | Feeling fresh | Rooms that don't feel stuffy | `.freshness` |
| 知 | Curiosity | Seeing what the air does | `.curiosity` |

**Q2** (single choice):
- Heading: "How often do you air your rooms now?"
- Hint: "CHOOSE ONE"

| Title | Subtitle | Value |
|-------|----------|-------|
| Rarely | Windows mostly stay shut | `AiringHabit.rarely` |
| Once a day | | `.onceADay` |
| A few times a day | | `.severalTimes` |
| A window is usually open | Tilted or ajar | `.windowUsuallyOpen` |

- **Footnote** (`.footnote`, `inkSoft`): "Your answers shape the tips and your plan. Change them any time in Settings."
- **Primary:** "Continue". Always enabled; an empty answer is allowed.
- **Writes:** §6.

### Screen 3: Breath (`breath`), science

- **Eyebrow:** 息 · BREATH
- **Title:** "Indoors, you breathe each other's air."
- **Illustration:** `BreathRoom` (§7.2). A hairline room with one person (人) breathing out puffs of ink motes that slowly fill it. A counter beneath (kukiLabel, then a numeral at 34 pt) counts up from "0%" to "1.5%" with the caption "OF EACH BREATH, ALREADY BREATHED". A small text button "Replay" sits under the counter.
- **Body:**
  1. *ink:* "Outside, air holds about 430 ppm of CO₂. Every breath out holds around 40,000 ppm, nearly a hundred times more."
  2. "So indoor CO₂ is a measure of air that's already been breathed. At 1000 ppm, roughly 1.5% of each breath was recently someone's exhale."
- **Personal line** (only if `freshness ∈ goals`, `.subheadline` italic, *ink*): "That stuffy feeling often starts here."
- **Sources:** NOAA GML (S1) · Rudnick & Milton 2003 (S2, S3, with the S3-note text) · the medical-device line (§5).
- **Primary:** "Continue"

### Screen 4: Night (`night`), science and interactive

- **Eyebrow:** 寝 · NIGHT
- **Title:** "A closed bedroom fills up fast."

**Phase A, guess** (shown first):
- Prompt (`Typeface.title`, *ink*): "Guess first: two people asleep, window shut, eight hours. Where does CO₂ end up?"
- Four choice chips in a horizontal flow that wraps at large sizes: "600", "1000", "2000", "4000" (ppm); each chip's accessibility label is "600 ppm".
- The bottom bar's primary button reads "Show me" until the reveal and reveals without a guess (`OnboardingModel.nightPrimary`); after it, "Continue".
- Tapping a chip or "Show me" starts Phase B.

**Phase B, simulator** (§7.3):
- **Hero** (exactly NowView's look, so it teaches the Now screen):
  - `AirMotes` inside an `EnsoRing` with the numeral in the middle and "ppm CO₂" kukiLabel.
  - Below it: level kanji and title (`CO2Level`).
  - Ensō size: `min(ensoScaled 220, width − 56, viewportHeight × 0.34)`.
- **Guess reply** (`.subheadline`, *ink*), shown once after the sweep. ~2080 is the model value at 2 sleepers and 8 h:

  | Guess | Reply |
  |-------|-------|
  | 2000 | "Close: about 2080 ppm." |
  | 4000 | "Lower than that: about 2080 ppm. Air leaks in even with the window shut." |
  | 600 or 1000 | "Most people guess lower: about 2080 ppm." |
  | Show me | "About 2080 ppm by morning." |

- **Controls:**
  - "People asleep": a segmented `Picker` with 1 / 2 / 3. Default 2 if `sleep ∈ goals`, else 2 (same; kept as a hook).
  - "Hours asleep": a `Slider` from 0 to 8, step 0.5, default 8. Value label: "8 h".
  - **"Open the window · 5 min"**: a secondary *button with border* (a `Capsule` stroke `Ink.ink` 1 pt, `Typeface.body`, height 44). Runs §7.3's airing. Afterwards the label becomes "Close the window" and resets to the closed-room curve.
- **Live readouts** (`.subheadline`, *ink*), updating as controls move:
  - Closed: "Past 1000 ppm after about {m} min." (from `BedroomModel.minutesToReach(1000, sleepers:)`, rounded to 5 min). If never reached within 8 h: "Stays under 1000 ppm all night."
  - After airing: "Window wide for 5 minutes: {before} → {after} ppm."
- **Caption** under the controls (`.footnote`, `inkSoft`): "Estimate for a 30 m³ bedroom with the window shut."
- **Body** (below the controls):
  1. *ink:* "In one study, student bedrooms averaged 2585 ppm with the window shut and 660 ppm with it open. With it open, students slept better and felt less sleepy the next day."
  2. "In a sleep lab, nights at 1000 ppm or more brought slightly less efficient sleep than nights at 750. Small studies, but they point the same way."
- **Personal line** (if `sleep ∈ goals`): "You chose sleep. Kūki will suggest a lower limit for you." (Only show it if the §6 limit suggestion applies.)
- **Sources:** Strøm-Tejsen et al. 2016 (S5, S6) · Kang et al. 2024 (S7) · Bekö et al. 2010 (S8) · Persily & de Jonge 2017 ("CO₂ from a sleeping adult, used in Kūki's estimate") · the medical-device line.
- **Primary:** "Continue". Enabled in both phases; skipping the guess is fine.

### Screen 5: The line (`line`), science and interactive

- **Eyebrow:** 線 · THE LINE
- **Title:** "1000 ppm is a signal, not a danger line."
- **Interactive dial** (§7.4):
  - The hero ensō (size as screen 4) with the numeral, then level kanji, title and **advice** (`CO2Level.advice`).
  - Below: a `Slider` from 420 to 2000 ppm, step 10, tinted `level.color`.
  - Under the slider, tick captions at their proportional positions: "800", "1000", "1400", "2000" (kukiLabel). The 1000 tick has a 1 pt `Ink.shu` hairline (the limit line).
- **Band note** (`.subheadline`, *ink*, below the advice), changing with the dial and diffusing via `.inkDiffuse`:

  | Range | Note |
  |-------|------|
  | < 800 | "Close to outdoor air." |
  | 800–999 | "Comfortable. Kūki starts suggesting a window." |
  | 1000–1399 | "Above the line Germany's Umweltbundesamt calls harmless." |
  | 1400–1999 | "Well past the line. Open a window wide." |
  | ≥ 2000 | "The Umweltbundesamt calls this unacceptable." |

- **Body:**
  1. *ink:* "Germany's Umweltbundesamt calls indoor air under 1000 ppm harmless, 1000–2000 ppm "conspicuous", and over 2000 unacceptable."
  2. "ASHRAE treats CO₂ as a sign of how well a room is ventilated, not as a health limit."
  3. "Some lab studies found slower decision-making at 1000–1400 ppm. Others added pure CO₂ and saw no change, so it may be the rest of stale air, not CO₂ alone."
  4. "Kūki is a little stricter: it calls air "getting stale" from 1000 ppm and "stuffy" from 1400."
- **Personal line** (if `focus ∈ goals`): "For focus: open a window before long work, not after."
- **Sources:** UBA 2008 (S9) · ASHRAE Position Document on Indoor CO₂ (S10) · Satish et al. 2012 · Allen et al. 2016 (S11) · Zhang et al. 2017 · Du et al. 2020 (S12) · the medical-device line.
- **Primary:** "Continue"

### Screen 6: How Kūki listens (`listen`), plus the fork

- **Eyebrow:** 聴 · LISTENING
- **Title:** "How Kūki hears the air"
- **Pipeline diagram** (§7.5): four captions on one hairline:

  `ALPSTUGA  ─ Thread ─  Home hub  ──  Apple Home  ──  Kūki`

  Each caption is kukiLabel. Under "Home hub" the hint "HomePod or Apple TV" appears in `.caption2`, `inkSoft`. A travelling ink dot moves along the line.
  - At widths < 360 or accessibility sizes, it stacks vertically with `chevron.down` hairlines.
  - VoiceOver (one element): "Your ALPSTUGA talks to a home hub over Thread. Apple Home passes its readings to Kūki."
- **Three feature rows**, each a leading mini-illustration (44 pt) plus text (`Typeface.body`, *ink* first sentence):
  1. Three static `EnsoRing`s, 28 pt each, `animated: false`: fractions 0.12 (matcha), 0.45 (kincha), 0.88 (shu).
     "The ensō grows with CO₂. A short stroke is clear air; a nearly closed circle means open a window."
  2. "居間 寝室 書斎" in mincho 15.
     "Tell Kūki which room the sensor is in. Carry it around and each room keeps its own history."
  3. 鈴 in mincho 26.
     "A soft fūrin rings once when the air crosses your limit."
- **Honest recording note** (a card: `Ink.paperRaised` fill, radius 14, padding 16; title in `Typeface.title`, body in `Typeface.body`):
  - **iPhone:** title "While Kūki is open". Body: "Apple Home shares readings only while Kūki is open on your iPhone. For an unbroken record, leave a spare iPhone or iPad in Station Mode, or let a Mac record from its menu bar."
  - **iPad:** the same with "on your iPad" and "leave a spare iPad or iPhone".
  - **Mac:** title "Around the clock". Body: "On this Mac, Kūki lives in the menu bar and records around the clock, even with its window closed. Look for it at the top of your screen."
- **Primary:** "Connect Apple Home". Goes to screen 7, primer state.
- **Secondary:** "No sensor yet? Try the demo". Turns on the demo and takes the demo path to screen 8 (§10.4).
- **Replay mode:**
  - If `homeKitRequested` is already true and authorization is granted, the primary reads "Continue" and screen 7 opens straight in detection.
  - If the demo is on, the secondary reads "Continue with the demo".

### Screen 7: Apple Home (`appleHome`)

One screen whose content is driven by `HomeConnectionState` (§8.2). Every state change crossfades the content block with `.inkDiffuse` (0.5 s), and the ensō area stays in place (§7.6, §7.7).

- **Eyebrow:** 家 · APPLE HOME
- The title changes per state.

#### 7a Primer (`.notRequested`)

- **Illustration:** a static `EnsoRing(fraction: 0.08, color: Ink.inkFaint, lineWidth: 6)` at 120 pt (EmptySensorView's look).
- **Title:** "Kūki reads your sensor through Apple Home."
- **Body:**
  1. *ink:* "Next, your iPhone will ask whether Kūki may use your Home data." (iPad: "your iPad". Mac: "Next, your Mac will ask…")
  2. "Kūki only reads air sensors: CO₂, temperature, humidity and particles. It never changes anything in your home, and readings stay on your devices."
- **Primary:** "Continue". This is the **only** button: no Back, no Skip, no secondary (R6).
- **Action:** `recorder.connectHomeKit()` (§10.1). Set `requestedAt = now`. The system alert appears; the state becomes `.waiting`.
- **System purpose string:** keep the existing `NSHomeKitUsageDescription`, "Kūki reads the CO₂, temperature, humidity and particle levels from your air quality sensor in Apple Home." It already meets privacy.md › Requesting permission (active, specific, ends with a period).

#### 7b Waiting (`.waiting`): system alert up, or Apple Home not answered yet (< 15 s)

- **Illustration:** the listening ensō (§7.6).
- **Title:** "Listening for Apple Home…"
- **Body:** "This usually takes a few seconds."
- No buttons. Skip is hidden while the system alert is up; after the alert, Skip and Back come back.

#### 7c Slow (`.slow`): still `.starting` at 15 s after `requestedAt`

- **Illustration:** the listening ensō, still running.
- **Title:** "Apple Home is taking its time"
- **Body:** "It can take up to a minute after your iPhone wakes. Check that you're signed in to iCloud and that the Home app shows your home." (Mac: "…after your Mac wakes…")
- **Primary:** "Check again". Calls `homeKit.recheck()` and resets the 15 s timer.
- **Secondary:** "Try the demo"
- If an answer arrives meanwhile, it transitions on its own, with no tap needed.

#### 7d Found: one sensor (`.found(sensor, ppm, fresh)`), the payoff

- **Searching to fresh reading** (fresh CO₂ heard after `requestedAt`; §8.2):
  - **Illustration:** the payoff (§7.7). The faint ring lifts, the brush paints to `EnsoRing.fraction(for: ppm)` in `CO2Level(ppm:).color`, the numeral appears, and the motes drift in.
  - **Title:** "There it is."
  - **Sensor line:**
    - Name in `Typeface.title`, *ink*: "{sensor.name}"
    - Under it, in `Typeface.body`, `inkSoft`: "{room} · {home}". Drop empty parts; no "·" when only one part remains.
  - **Reading line:** "{level.kanji} {level.title}" (kanji hidden from VoiceOver) and then "That's the air in {room} right now." Without a room: "That's the air around your sensor right now."
  - **Primary:** "Continue"
  - **VoiceOver announcement** (posted once): "Found {name} in {room}. {spoken ppm}, {level.title}."
- **Found but no fresh reading yet** (< 30 s after the sensor was found):
  - Title: "Found {name}"
  - Body: "Waiting for its first reading…"
  - The ensō keeps listening.
  - Primary: "Continue". Enabled; the user may move on.
- **Still no fresh reading after 30 s** (`ReachJudge.grace`):
  - *With a cached value:* the ensō paints to the cached ppm in `Ink.inkFaint` (no pigment, because the value is old).
    - Body: "Last reported {time, .shortened}. Apple Home hasn't sent a new reading yet. It often arrives within a minute."
    - Primary "Continue", secondary "Check again".
  - *Unreachable* (`sensor.isReachable == false`):
    - Title: "{name} is out of reach"
    - Body: "Apple Home can't reach it right now. Check that it's plugged in and near your home hub."
    - Primary "Continue", secondary "Check again".

#### 7e Found: several sensors (`.several([SensorInfo])`)

- **Title:** "Which sensor is yours?"
- **Body:** "Kūki follows one sensor at a time. You can switch in Settings."
- **List** of choice rows, single-select. Each row:
  - Leading: a static `EnsoRing(animated: false)` at 28 pt, at the cached or fresh ppm fraction, in the level colour if fresh and `inkFaint` if not. If the sensor has no CO₂, show a `circle.dotted` SF Symbol in `inkFaint`.
  - Title: the name.
  - Subtitle: "{room} · {home}", plus " · {ppm} ppm" when a fresh reading exists.
  - Preselected: the first row (HomeKitSource already sorts IKEA first).
- **Primary:** "Continue". Sets `recorder.selectedSensorID = row.id`, then shows **7d** for that sensor with the full payoff paint.
- Sensors that report no CO₂ (PM2.5 or air-quality only) get the subtitle "No CO₂ reading". They can be selected; NowView already handles "This sensor doesn't report CO₂".

#### 7f None: no home (`.noHome`; held ≥ 3 s, §8.2)

- **Illustration:** static faint ensō.
- **Title:** "Apple Home has no home yet"
- **Body:** "Set up your home in the Home app first, then add the sensor. Kūki will notice it here."
- **Primary:** "Open Home app" (§10.6). Hidden if the scheme can't be opened, in which case "Check again" becomes the primary.
- **Secondary:** "Check again" · "Try the demo"

#### 7g None: no air sensor (`.noSensor`; held ≥ 3 s)

- **Illustration:** static faint ensō.
- **Title:** "No air sensor in Apple Home yet"
- **Numbered guide** (three rows; leading numeral in mincho 22 (一 二 三), hidden from VoiceOver, which reads the list order):
  1. "Plug in your ALPSTUGA. It's ready to pair once it powers up."
  2. iOS: "In the Home app, tap + › Add Accessory, then scan the Matter code that came with the sensor."
     Mac: "Add it with the Home app on your iPhone or iPad. This Mac will see it a moment later."
  3. "Thread needs a home hub nearby: a HomePod mini, a HomePod (2nd generation), or an Apple TV 4K with Ethernet."
- **Footnote:** "Kūki will notice it as soon as it's added."
- **Primary:**
  - iOS 18+: "Add Accessory…". Presents Apple's setup sheet via `HMAccessorySetupManager().performAccessorySetup(using: HMAccessorySetupRequest())` (§10.6).
  - If that throws, or on Mac: "Open Home app"; if the scheme fails too, "Check again".
- **Secondary:** "Check again" · "Try the demo"
- **Automatic:** when `HMHomeDelegate.home(_:didAdd:)` fires, the existing `rescan()` runs, the state becomes `.found`, and 7d plays. Also re-check on `scenePhase == .active` (back from the Home app).

#### 7h Denied (`.denied`)

- **Illustration:** static faint ensō.
- **Title:** "Kūki can't see Apple Home" (same as EmptySensorView).
- **Body:** reuse `EmptySensorView.homeAccessMessage`. Expose it as `static var` (internal) and do not duplicate the copy:
  - iOS: "Allow Home access for Kūki in Settings, then come back."
  - Mac: "Allow Kūki in System Settings › Privacy & Security › Home, then come back."
- **Primary (iOS):** "Open Settings" → `UIApplication.openSettingsURLString`.
- **Primary (Mac):** none by default (matches EmptySensorView). If the deep link is verified (Open Question Q7), "Open System Settings".
- **Secondary:** "Try the demo"
- **Automatic:** `homeManager(_:didUpdate:)` already triggers `rescan()`; when access is granted the state moves on by itself.

**Skip on screen 7:** visible in every state except 7a and the alert-up part of 7b. It finishes onboarding with whatever is connected (§6.4).

### Screen 8: Where is it? (`place`), quiz Q3

- **Eyebrow:** 所 · PLACE
- **Title:**
  - Real sensor: "Where is the sensor right now?"
  - Demo: "Where would you like to start?"
- **Body:** "Kūki keeps a history for each room. Move it later from the Now screen."
- **Choice list** (single-select): the existing places sorted by `sortIndex` (seeded: 居間 Living room, 寝室 Bedroom, 書斎 Study, 台所 Kitchen). Then:
  - If the active sensor's Apple Home room doesn't match any place: one extra row, kanji column blank. Title "{room}", subtitle "From Apple Home". Value `.newPlace(name: room)`.
  - Last: "Somewhere else…". Tapping it expands an inline `TextField("Name the room", …)` with submit "Add". The field trims whitespace, allows 1–30 characters, and the row then shows the typed name, selected.
- **Preselection:** §6.2, `OnboardingPreselect.place`.
- **Primary:** "Continue"
- **Writes:** §6.

### Screen 9: The fūrin (`furin`), quiz Q4 and Q5

- **Eyebrow:** 鈴 · FŪRIN
- **Title:** "When should Kūki ring?"
- **Illustration** (small, 72 pt): 鈴 in mincho 34 with a hairline tanzaku strip below. It sways when the chime plays (§7.8).

**Q4, the CO₂ limit** (single-select rows):

| Title | Subtitle | Value |
|-------|----------|-------|
| 800 ppm · Sensitive | For bedrooms and sleep. Close to Europe's strictest bedroom level. | `LimitChoice.sensitive` (800) |
| 1000 ppm · The usual line | Where Germany's Umweltbundesamt stops calling air harmless. | `.standard` (1000) |
| 1200 ppm · Relaxed | Fewer chimes in busy rooms. | `.relaxed` (1200) |

- A "RECOMMENDED FOR YOU" kukiLabel tag sits on the row equal to `OnboardingPreselect.limit(goals:)`.
- Replay only: if the current `co2Limit` is none of the three, a fourth row "{n} ppm · Your current limit" is preselected.

**Q5, sound and notification:**
- `Toggle("Wind-chime sound", isOn:)`, preselected from `recorder.soundOn` (default true). A trailing borderless button with `speaker.wave.2` (label "Play the chime") calls `recorder.previewAlert()` and sways the fūrin.
- `Toggle("Also send a notification", isOn:)`, preselected from `recorder.notifyOn` (default false).
  - Turning it **on writes `recorder.notifyOn = true` immediately**, which triggers the system prompt through the existing `didSet → requestNotifications()`. This is the contextual ask; it is not staged.
  - Caption under it: "Your iPhone will ask first." (iPad: "Your iPad…". Mac: "Your Mac…")
  - If `recorder.notificationsDenied` becomes true, the toggle flips back off (Recorder already does this). Show Settings' existing denial copy (`Ink.ink`): "Notifications are turned off for Kūki. To get them, allow Kūki in {Settings › Notifications | System Settings › Notifications}, then turn Notification on again." (On Fūrin, the switch is named: "…then turn “Also send a notification” on again.")
- **Footer** (`.footnote`, `inkSoft`): "It rings once per stuffy spell, then waits until the air has clearly recovered. Change any of this in Settings."
- **Sources** (a small disclosure, because the limit rows cite standards): EN 16798-1 (S17) · UBA 2008 (S9) · Fan et al. 2023 (S18) · REHVA (S19).
- **Primary:** "Continue"

### Screen 10: Your plan (`plan`)

- **Eyebrow:** 始 · BEGIN
- **Title:** "Your plan"
- **Lines:** 3–5 rows from `OnboardingPlan.lines(answers:platform:demo:cloudAvailable:cloudOn:)` (§6.3). Each row has a leading ink brush dot (6 pt `Ink.ink` circle) and `Typeface.body`, *ink*. Each line's key fact is in `.weight(.medium)`.
- **Sources** (for the habit line): UBA (S13–S16).
- **Mac only**, below the lines: `Toggle("Open at Login", isOn:)`, default **off**, backed by `MenuBarBridge.shared.setOpenAtLogin(_:)`. Caption: "So Kūki is back in the menu bar after a restart." The toggle writes immediately; a login item is a system-level change the user makes explicitly.
- **Primary:** "Begin". Commits (§6.4), completes, and hands over to the app (§7.11).
- **Secondary:** none.
- **Top bar:** Back, progress. Skip is hidden, since Begin *is* finishing.

---

## 5. Sources disclosure (component)

`SourcesDisclosure(sources: [ScienceSource])`, used at the bottom of screens 3, 4, 5, 9 and 10.

- **Collapsed:** a button row with the text "Sources" (kukiLabel) and a trailing `chevron.down` (rotates 180° when open, 0.25 s easeInOut; no rotation with Reduce Motion, just a symbol swap). 44 pt tall.
- **Expanded:** a `VStack(alignment: .leading, spacing: 10)` of rows.
  - Each row is one `Link` (`Ink.ai`, `.footnote`) to `doi.org/…` or the official page. Visible text = `short` (e.g. "Satish et al. 2012 · Environmental Health Perspectives").
  - Under it, optional `note` (`.footnote`, `inkSoft`).
  - The last row is always: "Kūki shows what your sensor measures. It isn't a medical device." (`.footnote`, `inkSoft`)
- Use `DisclosureGroup` with a custom `DisclosureGroupStyle` so the look matches on Mac. Expanding does **not** scroll automatically, except at accessibility sizes, where it scrolls the first row into view.
- VoiceOver: the button label is "Sources", hint "Shows the studies behind this page", with `.isButton` and expanded state as the value.

```swift
struct ScienceSource: Identifiable, Hashable {
    let id: String            // "satish2012"
    let short: String         // "Satish et al. 2012 · Environmental Health Perspectives"
    let url: URL              // https://doi.org/10.1289/ehp.1104789
    var note: String? = nil
}
enum OnboardingSources { static let satish2012 = ScienceSource(...); /* one per row of §1.1 */ }
```

URLs:

| Source | URL |
|--------|-----|
| NOAA | https://gml.noaa.gov/ccgg/trends/ |
| Rudnick & Milton | https://doi.org/10.1034/j.1600-0668.2003.00189.x |
| Strøm-Tejsen | https://doi.org/10.1111/ina.12254 |
| Kang 2024 | DOI to fill; the DTU Orbit record until then |
| Bekö | https://doi.org/10.1016/j.buildenv.2010.04.014 |
| Persily & de Jonge | https://doi.org/10.1111/ina.12383 |
| UBA 2008 | Bundesgesundheitsblatt 51:1358–1369 (Springer link, or the umweltbundesamt.de PDF "hygienische_leitwerte") |
| ASHRAE | ashrae.org position-documents page |
| Satish | https://doi.org/10.1289/ehp.1104789 |
| Allen | https://doi.org/10.1289/ehp.1510037 |
| Zhang | https://doi.org/10.1111/ina.12284 |
| Du | https://doi.org/10.1111/ina.12706 |
| UBA Lüften | the umweltbundesamt.de pages named in §1.1 |
| EN 16798-1 | the REHVA Journal article "European standardisation on indoor air quality" (or the CEN catalogue) |
| Fan 2023 | https://pubmed.ncbi.nlm.nih.gov/37142023/ |
| REHVA | the rehva.eu COVID-19 guidance page |

---

## 6. Quiz: answers → settings

### 6.1 Model

```swift
enum AirGoal: String, CaseIterable, Codable { case sleep, focus, freshness, curiosity }
enum AiringHabit: String, CaseIterable, Codable { case rarely, onceADay, severalTimes, windowUsuallyOpen }
enum LimitChoice: Equatable, Codable {
    case sensitive, standard, relaxed, custom(Double)        // custom only in replay
    var ppm: Double { switch self { case .sensitive: 800; case .standard: 1000; case .relaxed: 1200; case .custom(let v): v } }
}
enum PlaceChoice: Equatable { case existing(UUID), newPlace(name: String) }
enum BedroomGuess: Int, CaseIterable { case p600 = 600, p1000 = 1000, p2000 = 2000, p4000 = 4000 }

struct OnboardingAnswers: Equatable {
    var goals: Set<AirGoal>? = nil          // nil = screen 2 not confirmed; [] = confirmed with none chosen
    var habit: AiringHabit? = nil
    var guess: BedroomGuess? = nil          // learning only, never written
    var place: PlaceChoice? = nil
    var limit: LimitChoice? = nil
    var soundOn: Bool? = nil
}
```

**An answer is recorded when that screen's primary button is tapped.** The preselection shown
then becomes the answer. Pressing Skip *on* a screen does **not** record that screen's
preselection.

### 6.2 Preselection (pure, unit-tested; `enum OnboardingPreselect`)

**`limit(goals:) -> LimitChoice`:** `.sensitive` if `goals` contains `.sleep`, else `.standard`.
Replay: the current `recorder.co2Limit`, mapped to the matching case or `.custom`. *(See Open Question Q1.)*

**`place(places:homeKitRoom:goals:current:) -> PlaceChoice`**, first rule that matches:
1. `homeKitRoom` (trimmed, non-empty) equals a place name, compared case- and diacritic-insensitively (`compare(_:options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame`) → `.existing(thatPlace)`.
2. `homeKitRoom` is non-empty and matches nothing → `.newPlace(name: homeKitRoom)`.
3. `.sleep ∈ goals` and a place named "Bedroom" exists → `.existing(Bedroom)`.
4. `.focus ∈ goals` and "Study" exists → `.existing(Study)`.
5. `current` is non-nil → `.existing(current)`.
6. Otherwise the first place by `sortIndex`.

**`sleepers(goals:) -> Int`:** 2 (one constant, kept as a hook).

### 6.3 Plan lines (`OnboardingPlan.lines`, pure, unit-tested)

The inputs are the answers, `platform ∈ {iPhone, iPad, mac}`, `demo`, `cloudAvailable` and `cloudOn`. The output is an ordered `[String]`.

1. **Place:**
   - Real sensor: "Start in the {place name} ({kanji})." Omit the parentheses when the place has no kanji. Then: " Move the sensor any time from the Now screen."
   - Demo: "The demo sensor starts in the {place name}. Connect a real one any time in Settings."
2. **Habit** (omitted if the habit is nil):

   | Habit | Line |
   |-------|------|
   | rarely | "Air out a few times a day: windows wide for a few minutes, about 3–5 in winter, 10–20 in summer." |
   | onceADay, sleep ∈ goals | "Add a second airing before bed. With two people asleep, a closed bedroom can refill in under an hour." |
   | onceADay, otherwise | "Add a second, short airing in the afternoon." |
   | severalTimes | "You already air often. Kūki will show which room needs it most." |
   | windowUsuallyOpen | "When it's cold, a few wide-open minutes beat a window tilted all day: fresher, and warmer." |

3. **Alert:**
   - Sound and notification both off: "No chime or notification. The ensō turns shu at {limit} ppm."
   - Otherwise: "The fūrin rings at {limit} ppm", then " and a notification follows." when notifyOn, else "."
   - When the limit is 800 and sleep ∈ goals, append " A gentle line for sleep."
4. **Recording:**
   - iPhone: "Kūki records while it's open. For a full night, try Station Mode on a spare device."
   - iPad: the same.
   - Mac: "This Mac records around the clock from the menu bar."
   - Mac with `showInDock == true`: "With a Dock icon, Kūki records only while it's in front. Settings › Show in Dock changes that."
5. **Sync** (only when `cloudAvailable && !cloudOn`): "Using Kūki on more than one device? iCloud Sync in Settings shares one history."

The limit and alert values come from what will be committed, so the plan always describes the settings the user is about to get.

### 6.4 Exact writes

Commit is `OnboardingCommit.apply(_ answers:, to sink: OnboardingSettingsSink, defaults: UserDefaults, places: PlaceStore)`. It runs on **Begin** (screen 10) and on **Skip** (any screen), with whatever answers exist.

| Answer | Writes | When | Effect in the app |
|--------|--------|------|-------------------|
| Q1 goals (non-nil) | `UserDefaults` `airGoals` = sorted raw values joined by "," (e.g. `"focus,sleep"`; `""` if none) | commit | Preselects Q3 and Q4, and the plan and personal lines. Stored for future tips. |
| Q2 habit | `airingHabit` = raw value | commit | The plan line, **and NowView advice** (§6.5) |
| Bedroom guess | nothing | – | Learning only (R14) |
| Apple Home: sensor chosen (7e) | `recorder.selectedSensorID` | **immediately** on Continue in 7e | Existing key `sensorID` |
| Apple Home: connect | `homeKitRequested = true` (new key) and `useDemo = false` | **immediately** (primer Continue) | HomeKit starts (§10.1) |
| Demo choice | `recorder.useDemo = true` | **immediately** | Existing key `useDemo` |
| Q3 place `.existing(id)` | `recorder.setStartingPlace(id)` (new; §10.2) | commit | Existing keys `placeID` and `placeChangedAt` |
| Q3 place `.newPlace(name)` | insert `Place(name:, kanji: "", sortIndex: max + 1)`, save, `recorder.placeEdited(place)` (sync hook), then `setStartingPlace(place.id)` | commit | A new place and the current place |
| Q4 limit | `recorder.co2Limit = limit.ppm` | commit | Existing key `co2Limit`; WidgetFeed picks it up on the next record |
| Q5 sound | `recorder.soundOn = value` | commit | Existing key `soundOn` |
| Q5 notification | `recorder.notifyOn = true/false` | **immediately** on toggle | Existing key `notifyOn`; the system prompt |
| Open at Login (Mac) | `MenuBarBridge.shared.setOpenAtLogin(_:)` | **immediately** on toggle | Login item |
| Completion | `hasCompletedOnboarding = true`, `onboardingVersion = 1`, remove `onboardingResumeStep` | commit | Root swap to the app |

Rules:
- A nil answer writes **nothing**: the existing value or registered default stays.
- Replay commits only on Begin. Close discards staged answers (immediate writes, such as notification, stay, since they already happened).
- The commit is idempotent.

New `UserDefaults.standard` keys:
- `hasCompletedOnboarding` (Bool)
- `onboardingVersion` (Int)
- `onboardingResumeStep` (String)
- `onboardingMigrated` (Bool)
- `homeKitRequested` (Bool)
- `airGoals` (String)
- `airingHabit` (String)

Put them all in one `enum OnboardingKeys` and reference them from Recorder's `Keys` where Recorder reads them. They live in the standard domain, not the App Group; widgets don't need them.

### 6.5 The habit changes NowView's advice (the persistent real effect of Q2)

Add a pure function in `Shared/AirLevel.swift`:

```swift
extension CO2Level {
    func advice(habit: String?) -> String   // raw AiringHabit, so Shared stays independent of the app target
}
```

- `.stale` with `"windowUsuallyOpen"`: "Open the window wide for a few minutes. Tilted, it airs slowly."
- `.poor` with `"windowUsuallyOpen"`: "Open it wide now. A tilted window can't keep up."
- Every other combination returns `advice` unchanged.

NowView (`HeroReading`) reads `@AppStorage("airingHabit")` and uses `level.advice(habit:)`. Widgets keep `advice`.

---

## 7. Motion

Defaults:
- Use SwiftUI built-ins: `PhaseAnimator`, `KeyframeAnimator`, `TimelineView` plus `Canvas`, and `contentTransition(.numericText)`.
- Every continuous animation pauses when:
  - its screen isn't current,
  - `scenePhase != .active`,
  - `\.motionPaused` is true (the Mac window is hidden; RootView already sets it), or
  - Reduce Motion is on.
- Canvas frame rate: 30 fps for interactive canvases, 15 fps for ambient ones (as `AirMotes`).
- Haptics: at most one per moment, `.impact(flexibility: .soft, intensity: 0.5)` as in `EnsoRing`, or `.selection` for crossing a band.
- With **Increase Contrast** (`@Environment(\.colorSchemeContrast) == .increased`), mote and particle alpha × 1.6, capped at 0.9.

### 7.1 Welcome: the ensō draws itself

Run `PhaseAnimator([.blank, .brush, .kanji, .words, .ready], trigger: appeared)` once on first appearance, or an equivalent `.task` sequence:

| t (s) | Event | Animation |
|-------|-------|-----------|
| 0.00 | The screen is visible; Skip is tappable | – |
| 0.25 | The brush lands; soft haptic | `EnsoRing` paints `painted 0 → 1` with its existing `.timingCurve(0.3, 0.0, 0.15, 1.0, duration: 1.6)` |
| 0.90 | 空気 inside the ring | opacity 0 → 1, `.easeOut(duration: 0.8)` |
| 1.40 | Title, then subtitle (+0.12 s), then body (+0.24 s) | `.inkDiffuse` insertion, `.easeOut(duration: 0.6)` each |
| 1.80 | The Begin button | opacity 0 → 1, `.easeOut(duration: 0.4)`. Its *hit-testing* is on from t = 0: a tap before it appears still works |

- Total: ≤ 2.2 s. Never auto-advances.
- Use `EnsoRing(fraction: 0.86, color: Ink.ink, lineWidth: 12, paintToken: "welcome", memory: localMemory)` with a fresh `EnsoPaintMemory` whose token starts as `"blank"`, so `newPlace` is true and the haptic fires.
- **Reduce Motion:** everything is drawn finished. The whole content fades in once (opacity, 0.3 s), with no haptic.

### 7.2 Breath room: particles accumulate

`BreathRoom(progress:)`, in a new file `Kuki/Onboarding/BreathRoom.swift`, drawn with `Canvas` in `TimelineView(.animation(minimumInterval: 1/30, paused: paused))`.

- **Room:**
  - A rounded rect at 4:3, `max width 320`, stroked `Ink.hairline` 1 pt, radius 18.
  - A window gap on the right wall (30% of its height, centred), drawn as two short hairline ticks.
  - The person: 人 in mincho 22 (`inkSoft`), 22% from the left, vertically centred.
- **Breathing:** a 4.0 s cycle (15 breaths a minute, compressed). On each exhale (cycle phase 0–1.2 s) one *puff* of 5 motes is born at the person's mouth (+14 pt right, −6 pt up).
- **Mote i** is deterministic, like `AirMotes`:
  - birth `bᵢ = floor(i / 5) × 4.0 s`; seeds `r1…r3 = fract(sin(i × 12.9898 × k) × 43758.5453)`.
  - age `τ = t − bᵢ` (skip if τ < 0).
  - initial heading `θ = −25° + 50° × r1`; speed `v₀ = 38 + 20 × r2` pt/s; drag `d = 1.6` s⁻¹.
  - travel `s = v₀ (1 − e^(−dτ)) / d` along θ, plus drift `sway = 6 pt × sin(τ × (0.3 + 0.4 r3) + i)` on both axes.
  - confinement: fold x and y into the room's inner rect with a triangle wave, so motes bounce softly with no physics.
  - size `1.6 + 1.4 × r3` pt; alpha `(0.30 + 0.25 × r2) × min(1, τ / 0.6)` (fades in over its first 0.6 s); colour `Ink.ink`.
- **Run:**
  - Plays once: 12 puffs (60 motes) over 48 s compressed to **9 s** (time × 5.33).
  - The rebreathed counter follows the mote count: `0.0% … 1.5%` (`String(format: "%.1f%%")`), displayed with `.contentTransition(.numericText(value:))`, `.smooth(duration: 0.3)`.
  - At the end it holds, and the Canvas stops ticking (`paused = true` once all puffs are born and drag has settled, τ > 3 s).
  - "Replay" resets `t₀` and plays again.
- **Reduce Motion:** no `TimelineView`. Draw the final state statically: 60 motes at their τ = ∞ positions (travel saturates at `v₀ / d`, sway = 0). The counter shows "1.5%". Replay is hidden.
- **Accessibility:** the Canvas is `accessibilityHidden`. The counter is one element, label "1.5 percent of each breath was already breathed".

### 7.3 Bedroom simulator: the ensō, pigment shift and window airing

The hero is `ZStack { AirMotes(ppm:, color:, reveal:, exclusion:, wind:) ; EnsoRing(...) ; numeral }`, mirroring `HeroReading`. The motes colour is `Ink.ink`, or `Ink.shu` at `.poor`, as NowView does.

**Additions to shared components** (additive, defaulted, so existing call sites don't change):
- **`EnsoRing(… fractionAnimation: Animation? = .easeInOut(duration: 1.2))`.** Replaces the hard-coded fraction animation. It is still `nil` when `reduceMotion || !animated`.
- **`EnsoRing(… colorAnimation: Animation? = .easeInOut(duration: 1.2))`.** The same treatment for colour.
- **`AirMotes(… wind: Double = 0)`**, passed to `MoteField`.
  - At `wind > 0`, each mote's x gets `+ wind² × 1.4 × age-in-gust` (unit radii per second), and motes past `d > 0.86` simply vanish (the existing edge guard).
  - `gustStart` is stored so motes accelerate from where they are.
  - It is `Animatable` so it can ramp.

**Sequence on entering Phase B** (`.sweep`):
- `displayHours` goes from 0 to the slider value (8) over **2.4 s**.
- Driven by `TimelineView(.animation(minimumInterval: 1/30))`, progress `p = easeInOut(elapsed / 2.4)`.
- `ppm = BedroomModel.ppm(sleepers:, hours: 8p)`.
- EnsoRing gets `fractionAnimation: nil` (it follows directly) and `colorAnimation: .easeInOut(duration: 0.5)`, so the pigment crossfades matcha → ink → kincha → shu as each band is crossed.
- The numeral text updates every frame. Do **not** use `.numericText` during the sweep; it is too costly per frame. Turn it on afterwards.
- One `.selection` haptic per band crossed (`sensoryFeedback(.selection, trigger: level)`).
- The guess reply then appears (`.inkDiffuse`, 0.6 s).

**Interaction:**
- **Hours slider drag:** `fractionAnimation: .interactiveSpring(response: 0.25, dampingFraction: 0.9)`, colour 0.4 s easeInOut, a selection haptic on band change. The level title and kanji diffuse with a 0.35 s `.inkDiffuse` instead of 0.8 s.
- **Changing People:** `fractionAnimation: .smooth(duration: 0.6)`.

**"Open the window · 5 min"** (2.0 s total):

| t (s) | Event |
|-------|-------|
| 0.0 | Soft haptic; `wind` 0 → 1, `.easeIn(duration: 0.4)` |
| 0.0 → 1.6 | `ppm` from `before` to `BedroomModel.afterAiring(from: before, minutes: 5, sleepers:)`, animated through a shown value with `.timingCurve(0.2, 0, 0, 1, duration: 1.6)` (a fast drop that settles, like exponential decay). EnsoRing `fractionAnimation` = the same curve; pigment steps back down (colour 0.5 s each band). `AirMotes` count follows its own 2 s fade. |
| 1.6 | `wind` 1 → 0, `.easeOut(duration: 0.4)` |
| 2.0 | Readout: "Window wide for 5 minutes: 2080 → 940 ppm." (rounded to 10) |

**Reduce Motion:**
- No sweep: the final value is shown at once and the guess reply appears.
- Slider changes update the ensō with no animation.
- Airing: the numeral crossfades (opacity 0.25 s); motes have no wind, and `AirMotes` is already still under Reduce Motion, with count changes as fades.

**VoiceOver:**
- The hero is one element: label "Estimated CO₂", value "{spoken ppm}, {level.title}".
- People and Hours are native controls with values "2 people" and "8 hours, {ppm} ppm, {level.title}".
- After airing, post an announcement: "Window open for 5 minutes. CO₂ falls to {ppm} ppm."

### 7.4 ppm dial (screen 5)

- The same hero. Slider binding `ppm` (420…2000).
  - Fraction: `.interactiveSpring(response: 0.25, dampingFraction: 0.9)`.
  - Colour: `.easeInOut(duration: 0.4)`.
  - Title, kanji, advice and band note: `.inkDiffuse` 0.35 s.
  - A `.selection` haptic on band change.
  - Motes: `AirMotes(ppm:)`. There are none below 800, by design: "their absence is the message".
- **Auto-glide on first appearance**, once:
  - A `KeyframeAnimator` on a local `demoPPM`: `LinearKeyframe(430, 0)` → `CubicKeyframe(1400, 1.6 s)` → `CubicKeyframe(1000, 1.2 s)`, 2.8 s total.
  - It writes through to `ppm`.
  - Any touch on the slider cancels it at once and hands control to the user.
  - It ends at 1000 to land on "the line".
- **Reduce Motion:** no glide; start at 1000.

### 7.5 Pipeline dot (screen 6)

- A 4 pt `Ink.ink` circle travels along the hairline from ALPSTUGA to Kūki.
  - `KeyframeAnimator(repeating: true)` on `x ∈ 0…1`: `CubicKeyframe(1, duration: 1.8)` with `.easeInOut` timing, then a `LinearKeyframe(1, duration: 0.6)` hold.
  - Opacity: 0 → 1 over the first 0.2 s and 1 → 0 over the last 0.2 s of the travel.
- On arrival the Kūki caption's mini ensō (16 pt, `animated: false`) pulses: `scaleEffect` 1 → 1.06 → 1 via `SpringKeyframe(duration: 0.3, bounce: 0)`.
- At ~15 fps-equivalent cost; pauses as §7's defaults.
- Above the Thread segment, the label "Thread" sits in `.caption2`, `inkSoft`.
- **Reduce Motion:** no dot. Small `chevron.forward` glyphs in `Ink.inkFaint` sit between captions.

### 7.6 Listening ensō (Apple Home waiting and slow)

- A static `EnsoRing(fraction: 0.08, color: Ink.inkFaint, lineWidth: 6)` at 120 pt.
- Three concentric `Circle().stroke(Ink.hairline, lineWidth: 1)` ripples (波紋, like water or a bell's sound), each:
  - `scale 0.9 → 1.5`, `opacity 0.6 → 0`, duration 2.4 s, `.easeOut`, staggered by 0.8 s.
  - Computed from a `TimelineView(.animation(minimumInterval: 1/30))` phase, not repeating implicit animations, so they stop cleanly.
- **Reduce Motion:** no ripples; the static ring only. The body text carries the state.

### 7.7 Found payoff

| t (s) | Event |
|-------|-------|
| 0.0 | No new ripples start; running ones finish their cycle (≤ 2.4 s, no cut). VoiceOver announcement. |
| 0.0 | The same `EnsoRing` view gets new inputs: `paintToken = sensor.id`, `color = level.color`, `fraction = fraction(for: ppm)`, `lineWidth 9` (animate the frame 120 → hero size with `.smooth(duration: 0.6)`). Its built-in choreography runs: the old stroke lifts (0.2 s), the brush lands (soft haptic), and paints (1.6 s). Use a local `EnsoPaintMemory` with a prior token so the haptic fires. |
| 0.6 | Numeral (`Typeface.numeral`) and "ppm CO₂": `.inkDiffuse` insertion, `.easeOut(0.6)`. After that, `.contentTransition(.numericText(value:))` for live updates. |
| 1.2 | Title "There it is." and the sensor lines: `.inkDiffuse`, 0.6 s, staggered 0.1 s |
| 1.8 | `AirMotes(reveal: 0 → 1)` (its own 2 s ease); none if ppm < 800 |
| 2.0 | The Continue button fades in (0.3 s). It is hit-testable from 0.0. |

- **Reduce Motion:** the final state is drawn at once (EnsoRing already sets `painted = 1`), the text has no blur, and the announcement is still posted.

### 7.8 Fūrin sway (screen 9, on "Play the chime")

- `KeyframeAnimator` on `rotation` (degrees, anchor `.top`):
  - `CubicKeyframe(7, 0.18)` → `CubicKeyframe(−5, 0.30)` → `CubicKeyframe(3.5, 0.30)` → `CubicKeyframe(−2, 0.30)` → `CubicKeyframe(0, 0.40)`, ≈ 1.5 s.
- The tanzaku strip follows with a 0.08 s lag and 1.4× amplitude.
- The trigger is a counter bumped by the play button. The `Chime` haptic already plays; add none.
- **Reduce Motion:** no sway; the sound only.

### 7.9 Progress dashes

The current dash's `trim` goes 0 → 1 with `.smooth(duration: 0.45)` when its step becomes current. Going back un-draws it with the same timing.

**Reduce Motion:** instant.

### 7.10 Step transitions

- **Forward:**
  - Insertion: `.opacity.combined(with: .offset(x: 24))`.
  - Removal: `.opacity.combined(with: .offset(x: −24))`.
  - `.smooth(duration: 0.45)`.
- **Back:** mirrored.
- **RTL:** flip the sign with `layoutDirection`.
- Use `.id(step)` on the content, with the transition chosen by direction.
- The top and bottom bars do not transition; only their contents crossfade (0.2 s).
- **Reduce Motion:** `.opacity`, `.easeInOut(duration: 0.25)`.

### 7.11 Handoff to the app (Begin, Skip)

- Root swap with `.transition(.opacity)` under `withAnimation(.easeInOut(duration: 0.5))`.
- NowView appears, and its `EnsoRing` paints for the first time: `recorder.ensoPaint.token` is nil on first run, so the app's "one orchestrated moment" happens right as onboarding ends. **Do not** pre-paint behind the onboarding; it must not be mounted until the swap (§10.3).
- `matchedGeometryEffect` across the swap was considered and rejected: NowView sits inside a `TabView` and the hero sizes differ. The fresh paint is the better handoff.
- **Reduce Motion:** a 0.25 s fade; the Now ensō is drawn finished.

### 7.12 Reduce Motion summary

| Animation | Full | Reduce Motion |
|-----------|------|---------------|
| Welcome ensō | 1.6 s brush, staggered text | Finished at once; a 0.3 s fade of the whole screen |
| Breath room | 9 s puffs filling a room | Static final room, counter at 1.5% |
| Bedroom sweep | 2.4 s 0 → 8 h, pigment crossfades | Final value at once |
| Window airing | Wind gust, 1.6 s decay | Numeral crossfade 0.25 s; motes fade |
| ppm dial | Auto-glide 2.8 s; spring follow | No glide; direct follow, no spring |
| Pipeline dot | Travelling dot, 2.4 s loop | Static chevrons |
| Listening | Ripples 2.4 s × 3 | Static faint ring |
| Found payoff | Lift, paint, motes | Final state; announcement |
| Fūrin | Keyframed sway | None |
| Transitions | Offset ±24 and fade, 0.45 s | Fade 0.25 s |
| `.inkDiffuse` (blur) | Blur 6 → 0 | Plain opacity (accessibility.md › Cognitive: avoid animating into blurs) |

Implement the last row once: `AnyTransition.inkDiffuseOrFade(reduceMotion:)` in `Kuki/Onboarding/`, so `Theme.swift`'s behaviour elsewhere stays untouched.

---

## 8. Pure logic (unit-tested)

### 8.1 `BedroomModel` (`Kuki/Onboarding/BedroomModel.swift`)

A single-zone mass balance: `dC/dt = G/V − n(C − C₀)`.

```swift
enum BedroomModel {
    static let outdoor = 430.0          // ppm (S1)
    static let volume = 30.0            // m³, ~12 m² × 2.5 m
    static let closedACH = 0.5          // h⁻¹, window shut (Bekö 2010: geometric mean 0.46)
    static let openACH = 15.0           // h⁻¹, window wide open (illustrative)
    static let perSleeper = 0.0126      // m³/h CO₂ = 0.0035 L/s (Persily & de Jonge 2017)

    /// Steady-state rise above outdoor, ppm.
    static func steadyRise(sleepers: Int, ach: Double) -> Double
        // = Double(sleepers) * perSleeper / (ach * volume) * 1e6
    static func ppm(sleepers: Int, hours: Double, start: Double = outdoor, ach: Double = closedACH) -> Double
        // outdoor + rise + (start − outdoor − rise) · e^(−ach·hours)
    static func minutesToReach(_ target: Double, sleepers: Int, start: Double = outdoor) -> Double?
        // nil if target ≥ outdoor + rise or sleepers == 0; else −ln(1 − (target−start)/(outdoor+rise−start)) / ach · 60
    static func afterAiring(from: Double, minutes: Double, sleepers: Int) -> Double
        // ppm(sleepers:, hours: minutes/60, start: from, ach: openACH)
}
```

Reference values (tests use ±1%):

| Case | Expected |
|------|----------|
| `ppm(2, 8)` | 2079 |
| `ppm(1, 8)` | 1255 |
| `ppm(3, 8)` | 2904 |
| `minutesToReach(1000, sleepers: 2)` | 49.7 |
| `minutesToReach(1000, sleepers: 1)` | 136.2 |
| `minutesToReach(1000, sleepers: 3)` | 30.8 |
| `afterAiring(from: 2079, minutes: 5, sleepers: 2)` | ≈ 942 |
| `afterAiring(…, minutes: 10, …)` | ≈ 617 |

Edge cases:
- `ppm(0, h) == outdoor`.
- `hours == 0 → start`.
- The result is monotonic in hours and sleepers.

### 8.2 `HomeConnectionState` (`Kuki/Onboarding/HomeConnection.swift`)

```swift
enum HomeConnectionState: Equatable {
    case notRequested
    case waiting
    case slow
    case denied
    case noHome
    case noSensor
    case found(SensorInfo, ppm: Double?, fresh: Bool)
    case foundWaiting(SensorInfo)          // found, no fresh CO₂ yet, < 30 s
    case unreachable(SensorInfo)
    case several([SensorInfo])
}

enum HomeConnection {
    static let slowAfter: TimeInterval = 15            // Apple Home takes 5–15 s after launch
    static let readingGrace: TimeInterval = ReachJudge.grace   // 30 s
    static let emptyHold: TimeInterval = 3             // don't flash "none" while homes are still loading

    static func state(requested: Bool, requestedAt: Date?, status: HomeKitSource.Status,
                      statusSince: Date, sensors: [SensorInfo], snapshots: [UUID: SensorSnapshot],
                      chosen: UUID?, foundAt: Date?, now: Date) -> HomeConnectionState
}
```

Evaluation order:
1. `!requested` → `.notRequested`.
2. `.notAuthorized` → `.denied`.
3. `.starting`: `.slow` if `now − requestedAt ≥ slowAfter`, else `.waiting`.
4. `.noHomes` or `.noSensors` held for `< emptyHold` (`now − statusSince`) → `.waiting`. Otherwise `.noHome` or `.noSensor`.
5. `.ready`:
   - If `sensors.count > 1 && chosen == nil` → `.several(sensors)`.
   - Otherwise take the sensor `s` (`chosen` or the only one). Let `snap = snapshots[s.id]`:
     - `snap?.isReachable == false` and `now − foundAt ≥ readingGrace` → `.unreachable(s)`.
     - `snap?.freshValue(.co2, now:)` exists **and** `snap.heardAt[.co2]! ≥ requestedAt` → `.found(s, ppm, fresh: true)`. This is a *fresh* reading heard after the request, never the cached first paint.
     - `now − foundAt < readingGrace` → `.foundWaiting(s)`.
     - Otherwise → `.found(s, ppm: snap?.co2, fresh: false)`.
   - A sensor with no CO₂ characteristic at all is `.found(s, nil, fresh: true)` once any metric is fresh.

The view re-evaluates on changes to `homeKit.status`, `sensors` and `snapshots`, and via a `TimelineView(.periodic(from: .now, by: 1))` for the timers. Time stamps:
- `statusSince` comes from a new `HomeKitSource.statusChangedAt`.
- `foundAt` is set the first time `.ready` with ≥ 1 sensor is seen.

### 8.3 Other pure units

- `OnboardingPreselect` (§6.2).
- `OnboardingPlan` (§6.3).
- `OnboardingCommit` (§6.4), against `OnboardingSettingsSink`:

  ```swift
  @MainActor protocol OnboardingSettingsSink: AnyObject {
      var co2Limit: Double { get set }
      var soundOn: Bool { get set }
      func setStartingPlace(_ id: UUID)
  }
  ```

  Recorder conforms. Tests use a fake plus `UserDefaults(suiteName:)`. Place creation goes through a small `PlaceStore` protocol (`insert(name:) -> UUID`) so the tests need no SwiftData.
- `OnboardingPath` (§3.3).
- `OnboardingMigration.run(defaults:)` (§10.7).
- `CO2Level.advice(habit:)` (§6.5).

---

## 9. Platforms and accessibility

### 9.1 iPhone

- The column layout.
- On compact heights (`viewport height < 720`, which includes the iPhone SE and the Duo outer display):
  - The hero ensō is 150–170 pt.
  - The welcome ensō is `min(200, width × 0.55)`.
  - On screen 4 the body facts sit below the controls (they scroll).
  - The bottom button stays pinned.

### 9.2 iPad and Mac (wide)

- At width ≥ 760, screens 3–5:
  - Two columns: illustration or interactive on the left (`frame(maxWidth: .infinity)`), text and Sources on the right (max 440). The whole is centred, max 1040 wide, and vertically centred (`minHeight` = viewport).
  - This uses NowView's `AnyLayout` HStack/VStack swap, so the hero keeps its identity across resizes and never repaints.
- Other screens: a single centred column, max 520.
- iPad Split View or Slide Over at compact width: the iPhone layout.

### 9.3 iPhone Duo

- **Outer display:**
  - 466 × 678 pt with an **84 pt trailing safe inset**, so the usable width is 382.
  - Compact-height rules apply (§9.1).
  - All chrome sits inside the safe area (§3.1): the top bar `HStack` and the bottom `safeAreaInset`. Nothing uses `ignoresSafeArea` except the paper background (`.paperBackground()`).
  - Verify Skip and the progress dashes never sit under the status column.
- **Inner display:** wide rules (§9.2).
  - When partly folded, the system reports a folding reserved region (HIG designing-for-iphone-duo.md › Reserved regions, "ReservedRegion (SwiftUI)"). Read it, and when present force the two-column layout with `spacing ≥ fold width + 32`, so the hero and the text sit on either side of the fold and no button straddles it. Check the exact API name in the current SDK.
- Don't move controls dramatically when folding (› Reserved regions: "favor small adjustments").

### 9.4 Mac (Catalyst, menu bar app)

- **Where it shows:**
  - In the **main window** (`WindowID.main`) on first launch, as a root swap inside `RootView` (§10.3).
  - The Settings and recorder windows are unaffected.
  - On first launch with onboarding incomplete, call `WindowRouter.shared.show(WindowID.main, using: openWindow)` in `RootView.onAppear` and bring the app forward. This covers launch at login too.
- **Window:**
  - The existing min size 560 × 620 and hidden title stay.
  - Content uses the wide or column rules by width.
  - Keyboard: §3.2.
  - Pointer: choice rows and buttons get `.quietHover(RoundedRectangle(cornerRadius: 14))`.
- **Copy differences:**
  - Screen 6 note: "Around the clock" / the menu bar, and look for it at the top of the screen.
  - The primer: "your Mac".
  - Denied: the System Settings path.
  - No sensor: add it on iPhone or iPad; no Add Accessory button.
  - Slow: "after your Mac wakes".
  - Plan: Open at Login, and the Mac recording line.
  - Notification caption: "Your Mac will ask first."
- **Menu bar during onboarding:**
  - The menu bar item exists (`MenuBarBridge.start` runs in `.task`).
  - While `hasCompletedOnboarding == false`, any menu-bar-item action other than Quit just shows the main window; in `MenuBarBridge.handle(_:)`, guard on the flag.
  - Air menu commands (Now, History, Move Sensor To, Station Mode, Export) are `.disabled(!hasCompletedOnboarding)`. Settings… (⌘,) stays enabled.
- **Closing the window mid-onboarding** is fine: the recorder window keeps the app alive. Reopening from the menu bar shows onboarding at the resume step.
- **Recording before completion:** none (§10.1, `holdRecording`).

### 9.5 Dynamic Type (to AX5)

- All text uses `Typeface` styles that scale. Numerals use `@ScaledMetric` clamped as in `HeroReading`.
- At `dynamicTypeSize.isAccessibilitySize`:
  - Progress dashes become the "3 of 10" caption.
  - Choice rows hide the kanji column (it is decorative) and let titles wrap (`.fixedSize(horizontal: false, vertical: true)`).
  - Chips (the screen 4 guess) become a vertical list.
  - The pipeline goes vertical.
  - The two-column wide layout falls back to one column.
  - Hero ensō sizes are capped at 40% of the viewport height so text and controls stay reachable.
  - The bottom bar keeps only the primary button pinned; secondary buttons move into the scroll content, so the pinned area never takes more than about 25% of the screen.
- Test at AX5 on an iPhone SE (3rd gen) and on the Duo outer display.

### 9.6 VoiceOver

Order per screen, using `.accessibilitySortPriority` where the visual order differs:
1. Progress ("Step n of N")
2. The title (header)
3. Subtitle and body
4. Interactive elements
5. The personal line
6. Sources
7. The primary button
8. Secondary buttons
9. Back
10. Skip

Further rules:
- Kanji: `accessibilityHidden`.
- Decorative canvases (breath room, ripples, pipeline dot, fūrin): hidden. The pipeline and hero have summary elements (§4, §7).
- Choice rows: `.accessibilityElement(children: .combine)`, with `.isSelected`. Multi-select Q1 gets the hint "Double-tap to choose. You can choose several."
- **State changes on screen 7 post announcements** (`AccessibilityNotification.Announcement`):
  - "Looking for Apple Home."
  - "Apple Home is taking its time."
  - "Found {name}…" (§4 7d)
  - "No air sensor found in Apple Home."
  - "Kūki can't see Apple Home."
- Focus moves to the new title after each step transition (`@AccessibilityFocusState`).
- Sliders have adjustable values with the units spoken ("8 hours", "1,000 ppm").

### 9.7 Increase Contrast, Bold Text, Dark Mode

- The colours come from `Ink`, which already handles Increase Contrast and Dark Mode.
- The mote and particle alpha boost is in §7.
- Selected rows use a 1.5 pt `Ink.ink` border plus a checkmark (not colour alone).
- Bold Text: `pageTitle(bold:)` and `numeral(bold:)` via `@Environment(\.legibilityWeight)`, as `PageTitle` does.

### 9.8 Resume (R8)

- On every step change, write `onboardingResumeStep = step.rawValue`.
- On launch with onboarding incomplete, start at that step. Exception: the saved step is `appleHome` but `homeKitRequested == false`; then use `listen`.
- Staged answers are not persisted. On resume, each remaining screen shows its preselection again.

---

## 10. Integration notes

The other agent is editing `Recorder.swift`, `KukiApp.swift`, `SettingsView.swift`, `Models.swift` and `Sync/` now. **Rebase onto their work and keep these changes small and additive.**

### 10.1 Recorder: hold HomeKit and recording until the user is ready

Today `Recorder.start` calls `homeKit.start()` whenever `!useDemo`, which pops the HomeKit prompt at first launch with no explanation. Change it as follows.

- `var homeKitRequested: Bool` is persisted (`OnboardingKeys.homeKitRequested`, registered default `false`).
- `start(container:)`: `if !useDemo && homeKitRequested { homeKit.start() }`
- `useDemo.didSet`: `if !useDemo, context != nil { connectHomeKit() }`. Turning the demo off in Settings *is* the user asking for Apple Home: a contextual request.
- New method:

  ```swift
  func connectHomeKit() {
      homeKitRequested = true
      if useDemo { useDemo = false }   // the simulator defaults to demo
      homeKit.start()                  // idempotent (guard manager == nil)
  }
  ```

- New: `var holdRecording = false` (not persisted). In `tick()`, skip `record(...)` and `checkAlert()` while it is true, so nothing is recorded or rung while the user is still choosing a sensor and a place. RootView sets it to `!hasCompletedOnboarding` on appear and on change. Replay does not hold.
- New `func setStartingPlace(_ id: UUID)`:
  - Sets `currentPlaceID = id`.
  - Sets `placeChangedAt = clock().addingTimeInterval(-Double(settleMinutes) * 60)`. **Settled already**: the sensor has presumably been sitting there; the wet-ink settling state should not show on first arrival.
  - Calls `alertGate.rearm()` and sets `lastRecordedAt = nil`.
  - Calls `syncHooks?.recorderDidMove(to: id, at: placeChangedAt)`.
  - Is a no-op if `id == currentPlaceID`. *(See Open Question Q3.)*

### 10.2 HomeKitSource (not in the other agent's list)

- `SensorInfo` gets `home: String` (from the `HMHome` the accessory was found in, `home.name`). Update `rescan()` and any `SensorInfo` initialisers and tests.
- `private(set) var statusChangedAt = Date.now`, set whenever `status` changes.
- `private(set) var isStarted: Bool { manager != nil }` (for tests and the "not connected" empty state).
- `func recheck()` (public): calls `rescan()` and then `Task { await refresh() }`. Used by "Check again" and on `scenePhase == .active`.
- `func addAccessory() async throws` (iOS; `#if !targetEnvironment(macCatalyst)`):

  ```swift
  let result = try await HMAccessorySetupManager().performAccessorySetup(using: HMAccessorySetupRequest())
  ```

  then `recheck()`. The user may cancel; on cancel, do nothing. **Verify on device:** that it presents the system Add Accessory sheet with no payload, that it works with only the HomeKit entitlement, and what it does when there is no home. If it misbehaves, ship "Open Home app" as primary (§4 7g).

### 10.3 Presentation: root swap inside RootView

- In `RootView.body`, replace the bare `TabView(...)` with:

  ```swift
  Group {
      if showOnboarding { OnboardingFlow(mode: hasCompletedOnboarding ? .replay : .firstRun) }
      else { TabView(...) { ... } ... }     // unchanged tabs and their modifiers
  }
  .transition(.opacity)
  ```

  - `@AppStorage(OnboardingKeys.hasCompleted) var hasCompletedOnboarding = false`.
  - `showOnboarding = !hasCompletedOnboarding || nav.replayingOnboarding`.
  - Keep **all** of RootView's outer modifiers (`SceneReader`, `scenePhase`, Mac titlebar and size, `onAppear` window routing, Station cover, `fileExporter`) outside the `Group`, so they work during onboarding too.
- `AppNav` gets `var replayingOnboarding = false`.
- Why a root swap and not a `fullScreenCover`:
  - It keeps NowView unmounted, so its first ensō paint is saved for the handoff (§7.11).
  - It avoids Catalyst's cover environment trap: covers are hosted outside the view tree, as the existing Station cover comment warns.
  - It needs no second presentation for replay.
- Pass `recorder`, `nav` and `modelContext` through the environment (already present in RootView).

### 10.4 Demo path ("No sensor yet? Try the demo")

- The demo setting is `Recorder.useDemo` (key `"useDemo"`; registered default `Recorder.isSimulator`). Settings shows it as "Demo sensor".
- The demo button sets `recorder.useDemo = true` and switches the path to demo, skipping `appleHome`. HomeKit is **not** started, and `homeKitRequested` stays false.
- In the app, NowView shows the demo reading.
- Settings › Demo sensor off → `connectHomeKit()` → the system prompt. Settings' existing footer explains Apple Home. Add one footer sentence when `!homeKitRequested`: "Turning the demo off connects Kūki to Apple Home."
- **New empty state:** in `EmptySensorView`, when `!recorder.useDemo && !recorder.homeKitRequested` (only reachable via Skip before connecting):
  - Title: "Kūki isn't connected to Apple Home yet"
  - Body: "Connect to read your air sensor."
  - Buttons: "Connect Apple Home", which presents `AppleHomeConnectSheet` (screen 7 as a sheet: primer → detection, with Done instead of Continue), and "Try the demo".

### 10.5 App Review

- The reviewer sees onboarding first. The fastest path into the app is **Skip** on screen 1, one tap, and it is visible from the first frame.
- They then see the "not connected" empty state, which has an obvious "Try the demo".
- On screen 6, "No sensor yet? Try the demo" is a visible secondary button.
- Every Apple Home failure state has "Try the demo" (hidden in a replay that is already on Apple Home).
- Add to `docs/APP_STORE.md` review notes: "No sensor needed: tap Skip, then Try the demo — or on 'How Kūki hears the air' choose 'No sensor yet? Try the demo'."
- The primer has only "Continue", per HIG, so the reviewer will see the system prompt if they choose Connect. That is expected.

### 10.6 Opening the Home app

- Try `URL(string: "com.apple.home://")!` with `openURL(url) { accepted in … }`.
  - Community reports say this scheme opens Home; it is **undocumented**.
  - Add `com.apple.home` to `LSApplicationQueriesSchemes` (in `Config/Info.plist` or as an `INFOPLIST_KEY`), and check `UIApplication.shared.canOpenURL` up front to decide whether to show the button at all.
  - If `accepted == false`, replace the button with the text "Open the Home app".
- Verify on iOS 18 and 26/27 devices and on Mac Catalyst. The Mac Home app may or may not register it.
- On the Mac, the Home app can't add accessories, so the guide routes to iPhone or iPad (verify on the current macOS).

### 10.7 Migration and Debug

`OnboardingMigration.run(defaults:)` is called at the top of `Recorder.init`, **before** `configure()` can set `seededPlaces`:

```swift
#if DEBUG
if defaults.bool(forKey: "resetOnboarding") {          // -resetOnboarding YES
    for k in [hasCompleted, version, resumeStep, homeKitRequested, airGoals, airingHabit] { defaults.removeObject(forKey: k) }
    defaults.set(true, forKey: migrated)
    return
}
#endif
guard !defaults.bool(forKey: migrated) else { return }
defaults.set(true, forKey: migrated)
if defaults.object(forKey: "seededPlaces") != nil {    // an existing install: no onboarding, HomeKit as before
    defaults.set(true, forKey: hasCompleted)
    defaults.set(true, forKey: homeKitRequested)
}
```

- `-resetOnboarding YES` exists only in DEBUG builds. It does not reset the HomeKit or notification TCC grants.
  - On a device, reinstall to test the prompt.
  - On the Mac, `tccutil reset Willow com.olshanskysoft.kuki` (HomeKit's TCC service is believed to be "Willow"; verify) and `tccutil reset Notifications …`.
- Also DEBUG only: `-onboardingStep <rawValue>` starts at a step (for screenshots and checks). `-onboardingStep appleHome` implies `homeKitRequested`.
- The Simulator has no Apple Home: Connect lands on 7f, "no home". Use it to check the guide states, and use the demo for the rest.

### 10.8 Settings: "Replay introduction"

- Add a final section to `SettingsView`:
  - Header: "Introduction"
  - Row: `Button("Replay introduction")`
  - Footer: "Why air matters, how Kūki works, and your plan — a few minutes."
- Action: `nav.replayingOnboarding = true`.
  - iOS: also `nav.tab = .now`, so leaving replay lands on Now.
  - Mac: also `WindowRouter.shared.show(WindowID.main, using: openWindow)`. The Settings window stays where it is.
- **Replay mode:**
  - Skip reads "Close" and discards staged answers.
  - Begin commits.
  - The primer is skipped if `homeKitRequested`.
  - Preselections come from the current settings (§6.2).
  - No `holdRecording`.
  - The resume step is not written.

### 10.9 File layout

```
Kuki/Onboarding/
  OnboardingFlow.swift          container, top/bottom bars, transitions, step routing, resume, Skip/Close
  OnboardingModel.swift         @Observable: step, path (demo?), answers, requestedAt, foundAt, mode
  OnboardingKeys.swift          UserDefaults keys; OnboardingMigration
  OnboardingAnswers.swift       AirGoal, AiringHabit, LimitChoice, PlaceChoice, BedroomGuess, OnboardingAnswers
  OnboardingLogic.swift         OnboardingPath, OnboardingPreselect, OnboardingPlan, OnboardingCommit, sink protocols
  OnboardingSources.swift       ScienceSource + every citation of §1.1
  SourcesDisclosure.swift
  ChoiceRow.swift               quiz row + chip
  OnboardingMetrics.swift       layout constants (§2), inkDiffuseOrFade
  BedroomModel.swift
  HomeConnection.swift          HomeConnectionState + reducer
  BreathRoom.swift              §7.2 canvas
  ListeningRipples.swift        §7.6
  PipelineDiagram.swift         §7.5
  Screens/WelcomeScreen.swift, QuestionsScreen.swift, BreathScreen.swift, NightScreen.swift,
          LineScreen.swift, ListenScreen.swift, AppleHomeScreen.swift, PlaceScreen.swift,
          FurinScreen.swift, PlanScreen.swift
  AppleHomeConnectSheet.swift   screen 7 reused as a sheet (§10.4)
```

Changes to existing files, kept minimal:
- `Shared/EnsoRing.swift`: the `fractionAnimation` and `colorAnimation` parameters; `AirMotes` and `MoteField` `wind`.
- `Shared/AirLevel.swift`: `advice(habit:)`, the poor-advice copy, the "~430" comment.
- `Kuki/Sensor/Recorder.swift`: §10.1.
- `Kuki/Sensor/HomeKitSource.swift`: §10.2.
- `Kuki/KukiApp.swift`: RootView swap, `AppNav.replayingOnboarding`, commands disabled, Mac show-main.
- `Kuki/Views/NowView.swift`: `EmptySensorView` "not connected" state, `homeAccessMessage` made internal, `advice(habit:)`.
- `Kuki/Views/SettingsView.swift`: the Replay row and the demo footer sentence.
- `Kuki/Bridge/MenuBarBridge.swift`: the onboarding guard in `handle`.
- The Info.plist query scheme.
- `docs/APP_STORE.md` review notes; `README.md` "Build" (mention `-resetOnboarding YES`).

---

## 11. Acceptance criteria

### 11.1 Unit tests (Swift Testing, `KukiTests/OnboardingTests.swift`)

| Suite | Cases |
|-------|-------|
| `BedroomModel` | The §8.1 reference values (±1%); `sleepers == 0` stays at outdoor; monotonic in hours and sleepers; `minutesToReach` is nil when unreachable; airing lowers ppm and 10 min < 5 min |
| `OnboardingPreselect.limit` | `[]` → 1000; `[.focus]` → 1000; `[.sleep]` → 800; `[.sleep, .focus]` → 800; replay 1150 → `.custom(1150)` |
| `OnboardingPreselect.place` | HomeKit room "bedroom" → Bedroom (case-insensitive); "Büro" with no match → `.newPlace("Büro")`; empty room + sleep → Bedroom; focus only → Study; none → current; no current → first by `sortIndex`; "  Kitchen " (whitespace) → Kitchen |
| `OnboardingCommit` | Each `LimitChoice` writes exactly 800/1000/1200 to `co2Limit`; nil limit leaves `co2Limit` untouched; `soundOn false` written; goals written as sorted CSV, `[]` writes `""`, nil writes nothing; habit raw value written; `.newPlace` inserts one place and calls `setStartingPlace` with its id; completion keys set and resume key removed; replay Close writes nothing; the commit is idempotent |
| Skip semantics | Skip on screen 9 before Continue does **not** write the limit preselection; Skip after screen 8's Continue writes the place |
| `OnboardingPlan.lines` | One test per habit row of §6.3; the alert line for each sound/notify combination; Mac vs iPhone recording line; the demo place line; the sync line only when available and off; every line non-empty and without the word "health" |
| `HomeConnection.state` | not requested; `.notAuthorized` → denied; starting at 14 s → waiting, at 15 s → slow; `.noSensors` at 2 s → waiting, at 3 s → noSensor; `.noHomes` → noHome after hold; one sensor with only a cached value heard **before** `requestedAt` → foundWaiting (not found); fresh after request → found(fresh); 2 sensors, none chosen → several; 2 with chosen → found for the chosen one; unreachable at 30 s → unreachable; no fresh reading at 30 s → found(fresh: false) |
| `OnboardingPath` | Full = 10 steps; demo = 9, no appleHome; indices are consistent |
| `OnboardingMigration` | Fresh defaults → not completed, not requested, migrated; `seededPlaces` present → completed and requested; second run is a no-op; DEBUG reset removes the keys and keeps migrated |
| `Recorder` gate | `start` with `homeKitRequested == false` and `useDemo == false` → `homeKit.isStarted == false`; `connectHomeKit()` → requested and started, and `useDemo` false; `holdRecording` → `record` not called by `tick` (test via `lastRecordedAt` staying nil with the demo on); `setStartingPlace` → `isSettling == false`, `currentPlaceID` set |
| `CO2Level.advice(habit:)` | stale and poor change only for `"windowUsuallyOpen"`; clear and fine never change; a nil or unknown habit returns the default |

### 11.2 Per-state acceptance (Apple Home)

| State | Must |
|-------|------|
| Primer | Exactly one button ("Continue"); no Skip or Back; the copy names what is read; tapping triggers exactly one system HomeKit prompt; HomeKit was **not** touched before this tap (no `HMHomeManager` exists; verified by `isStarted`) |
| Waiting | Shows ripples (or the static ring under Reduce Motion); no buttons; Skip comes back after the alert; never auto-advances to a failure state before 15 s (slow) or 3 s of a stable empty status |
| Slow | Appears at 15 s; Check again resets the timer and calls `recheck`; transitions to the right state by itself when Apple Home answers |
| Found (one) | Name, room and home shown, empty parts dropped; the ensō paints to a **fresh** reading heard after the request; the level pigment matches `CO2Level`; one soft haptic; VoiceOver announcement; Continue works mid-animation |
| Found, waiting | Never shows a cached value as live; after 30 s, a cached value is drawn in `inkFaint` with its time; unreachable shows the out-of-reach copy; Continue always available |
| Several | Every sensor listed with room · home; IKEA preselected first; Continue writes `selectedSensorID` and plays the payoff for that sensor; switching later in Settings still works |
| No home | Appears only after a 3 s stable `.noHomes`; Open Home app present only if the scheme can open; Check again and demo present |
| No sensor | The three-step guide with the Thread hub line; iOS has Add Accessory… (falls back to Open Home app on error); Mac routes to iPhone or iPad; adding the sensor in Home while Kūki is open moves to Found **without** a tap |
| Denied | The title matches EmptySensorView; iOS "Open Settings" opens Kūki's Settings page; Mac shows the System Settings path; granting access in Settings and returning moves on by itself |
| Demo instead | Sets `useDemo`, never starts HomeKit, and continues to the place screen on the demo path (N = 9) |

### 11.3 Flow, platform and accessibility checks (manual; record in the PR)

- [ ] Fresh install on iPhone: no system prompt before screen 7's Continue. Notification prompt only when its toggle turns on.
- [ ] Skip on screen 1 → app in ≤ 0.5 s; the Now "not connected" state offers Connect and the demo.
- [ ] Kill the app on screen 8 and relaunch → resumes on screen 8.
- [ ] Begin → Now's ensō paints once (not twice; not already painted).
- [ ] An existing install upgraded → no onboarding, HomeKit behaves as before.
- [ ] Settings › Replay introduction → flow with current values preselected; Close changes nothing; Begin commits.
- [ ] Mac:
  - onboarding in the main window on first launch, also when launched at login;
  - menu bar actions just show the window;
  - Air menu commands disabled;
  - Esc on the primer does nothing;
  - Open at Login toggle works;
  - closing the window mid-flow and reopening from the menu bar resumes.
- [ ] iPad landscape, and a Mac window at 1200 wide → two-column science screens; resizing across 760 doesn't repaint the hero.
- [ ] iPhone Duo outer display (466 × 678, 84 pt trailing inset): Skip and progress fully visible and tappable; no clipped text at default and AX3; inner display partly folded: nothing on the fold.
- [ ] AX5 on an iPhone SE: every screen reachable; primary always visible; no truncated copy.
- [ ] VoiceOver: the order of §9.6; all announcements fire; the sim and dial are adjustable with spoken units.
- [ ] Reduce Motion: every row of §7.12; no blur anywhere in onboarding.
- [ ] Increase Contrast plus Dark Mode: legible on all screens; selected rows distinguishable without colour.
- [ ] No raw colours: `grep -n "Color(" Kuki/Onboarding` shows only `Ink.*` use; no `.white`, `.black` or hex.

### 11.4 Device-gated items (Gradle-equivalent builds can't prove these; call them out)

- `HMAccessorySetupManager` sheet behaviour.
- The `com.apple.home://` scheme (iOS and Catalyst).
- The Mac TCC prompt copy and path.
- The HomeKit timings (5–15 s) on a real home with an ALPSTUGA.
- The payoff with a live reading.
- Duo fold behaviour.

---

## 12. Build order

1. Pure logic, with tests: `BedroomModel`, answers, preselect, plan, commit, path, migration, `HomeConnection`, `advice(habit:)`.
2. Recorder and HomeKitSource gates (§10.1–10.2), with tests. Coordinate with the agent editing Recorder.
3. Shell: `OnboardingFlow`, bars, transitions, resume, RootView swap, the Mac window and commands.
4. Screens 1, 2, 6, 8, 9 and 10 (static plus quiz).
5. Screen 7: all states, the sheet variant, the EmptySensorView "not connected" state.
6. Science screens 3–5 with their animations, then the `EnsoRing` and `AirMotes` additions.
7. Settings Replay, the App Store notes, the README.
8. The §11.3 pass; fill the Kang 2024 DOI; verify the Persily value and the Allen numbers if ever shown.

---

## 13. Open Questions for the developer

- **Q1. Should the quiz change the default CO₂ limit?** As specified, choosing *Sleep* preselects 800 ppm on screen 9 (EN 16798-1 Cat I bedrooms ≈ 810; the sleep studies suggest ≤ 800). It is only a preselection the user confirms, but it means sleep-focused users hear the fūrin more often (it re-arms at 700). The alternative is to always preselect 1000 and show 800 as "suggested for sleep".
- **Q2. Ten screens, against your "about 6–9".** The full path is 10 (9 with the demo). The cheapest cut is merging screen 5 (The line) into screen 3 (Breath), giving 9 and 8, at the cost of the ppm dial or the UBA/ASHRAE framing. The alternative is moving the quiz screen 2 after the science. Keep 10?
- **Q3. First place: settled or settling?** `setStartingPlace` treats the sensor as already settled, assuming it has been sitting there. If users typically unbox and place it during onboarding, use `move(to:)` instead, so the 10-minute settling and wet ink show honestly.
- **Q4. Existing advice copy.** OK to change `CO2Level.poor.advice` from "Ventilate now — focus and sleep suffer." to "Ventilate now — open a window wide."? The current wording states contested science as fact (Guideline 1.4.1 risk).
- **Q5. Airing-habit reminders.** Q2 currently changes the plan and NowView's advice. Do you also want an optional "airing rhythm" reminder (scheduled local notifications, e.g. morning and evening), driven by the habit answer? That is a new feature, not specified here.
- **Q6. Goals beyond preselection.** Q1 is stored (`airGoals`) but only drives preselections, personal lines and the plan. Should it later tune History's takeaway (e.g. sleep → bedroom night stats first)?
- **Q7. Mac deep link to Home privacy.** Is a "Open System Settings" button wanted on the Mac denied state (e.g. `x-apple.systempreferences:com.apple.preference.security?Privacy_HomeKit`, unverified on Catalyst), or keep text only as today?
- **Q8. Outdoor baseline.** The onboarding uses 430 ppm (NOAA 2025–26). `EnsoRing.fraction(for:)` still maps from 400. Leave the ensō mapping as is (visual only)?
- **Q9. Localisation.** Place names are seeded in English, and HomeKit room matching (§6.2) compares against them. When Kūki is localised, should seeding follow the system language?
