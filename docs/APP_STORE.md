# Putting Kūki on the App Store

One app record covers **iPhone, iPad and Mac** (same bundle ID `com.olshanskysoft.kuki`, so it's one purchase on all three). Team `S6PVT5UP7G`.

Already done in the project:
- Privacy manifests (`Kuki/PrivacyInfo.xcprivacy`, `KukiWidget/PrivacyInfo.xcprivacy`): no tracking, no data collected, two required-reason APIs declared.
- `ITSAppUsesNonExemptEncryption = NO`, so there's no export-compliance question at each upload.
- Release builds verified for iPhone and Mac: no debug switches inside.
- Privacy policy text: [`PRIVACY.md`](../PRIVACY.md).

Work through the steps in order. Rough time: an afternoon, plus Apple's review (usually 1–2 days).

---

## 1. Before anything: decide what Kūki promises

Apple Home only gives sensor values to the app **in front**, on iPhone and on Mac alike. The listing and screenshots must not promise background recording. Use wording like:

> Records while Kūki is open. Leave it in **Station Mode** on a spare iPhone, iPad or Mac to record around the clock.

## 2. iCloud: deploy the data layout to Production (required)

The iCloud record Kūki uses (`LatestAir`) currently exists only in the **Development** environment. App Store builds use **Production**, and without this step sync silently does nothing for real users.

1. Run a signed Debug build once with iCloud Sync on and a real reading, so the record type exists in Development. You've already done this.
2. Open **https://icloud.developer.apple.com** › **CloudKit Console** › container **iCloud.com.olshanskysoft.kuki**.
3. **Schema › Indexes:** for record type `LatestAir`, add a **Queryable** index on `recordName`. iCloud wake-up subscriptions need it.
4. **Schema › Deploy Schema Changes…** › deploy to **Production**.

## 3. App Store Connect: create the app

1. **https://appstoreconnect.apple.com** › **Apps** › **+** › **New App**.
2. Fill in:
   - **Platforms:** iOS, plus macOS (you can also add macOS later from the app page: **+ Add Platform**).
   - **Name:** `Kūki`. If it's taken, try `Kūki — Room Air`.
   - **Primary language:** English.
   - **Bundle ID:** `com.olshanskysoft.kuki`.
   - **SKU:** `kuki-1`.
   - **User access:** Full Access.

## 4. App information

| Field | Suggested value |
|---|---|
| Subtitle (≤ 30 chars) | `CO₂, room by room` |
| Category | Primary **Lifestyle**, secondary **Utilities** |
| Age rating | Answer "None" to everything → **4+** |
| Privacy Policy URL | `https://github.com/LubomirOlshansky/Kuki/blob/main/PRIVACY.md` (or host the same text at `stillplace.app/kuki/privacy`) |
| Copyright | `2026 Lubomir Olshansky` |
| Price | Free (Pricing and Availability) |

**App Privacy** (the "nutrition label"): click **Get Started** › **"No, we do not collect data from this app"**. This is true: readings stay on the device and in the user's own iCloud.

## 5. Store text

**Description** (edit freely):

> Kūki (空気, "air") shows how fresh the air is in the room where your sensor sits, quietly.
>
> Works with air-quality sensors in Apple Home, such as the IKEA ALPSTUGA: CO₂, temperature, humidity and PM2.5.
>
> • An ensō brush circle that grows with CO₂, and plain advice: clear air, fine, getting stale, stuffy.
> • Move the sensor between rooms and compare them: history per place, averages, peaks, time over your limit.
> • A soft wind-chime when it's time to open a window.
> • Widgets, Lock Screen and Live Activity.
> • Mac app with the reading in the menu bar.
> • Export to CSV, or an AI-ready summary for Claude or ChatGPT.
> • Station Mode: leave a spare device on a charger and record around the clock.
>
> Records while Kūki is open (Apple Home only updates the app in front). No account, no tracking: your readings stay on your devices.

**Keywords** (≤ 100 chars): `co2,air quality,carbon dioxide,homekit,sensor,ventilation,humidity,pm2.5,indoor air,room`

**Trademarks:** saying *works with IKEA ALPSTUGA* is fine. Don't put IKEA in the name, subtitle or icon, and don't use IKEA's logo (App Review Guideline 5.2).

## 6. Screenshots

Required sizes (simulator screenshots are accepted):

| Device | Size | Simulator to use |
|---|---|---|
| iPhone 6.9" | 1320 × 2868 | iPhone 17 Pro Max |
| iPad 13" | 2064 × 2752 | iPad Pro 13-inch (M5) |
| Mac | 2880 × 1800 (or 1280 × 800) | your Mac, ⇧⌘5 on the Kūki window |

Suggested set of 4–6: **Now** (light) · **History** with the headline · **Now** (dark) · **Station Mode** · **Lock Screen widget / Live Activity** · **Export**.

To use demo data in the simulator, launch with: `xcrun simctl launch <device> com.olshanskysoft.kuki -useDemo YES -seedDemoOnLaunch YES` (Debug builds only).

## 7. Notes for App Review (important)

Reviewers won't own an air sensor. Paste this into **App Review Information › Notes**:

> Kūki reads air-quality sensors (e.g. IKEA ALPSTUGA) through HomeKit. To review without a sensor: open **Settings** (iPhone: Settings tab; Mac: Kūki › Settings… or ⌘,) and turn on **Demo sensor**. Optional: tap **Add 3 days of demo history** to see History and Export. HomeKit access is used only to read sensor values; nothing is controlled or sent anywhere. iCloud stores only the latest reading in the user's private database.

Sign-in required: **No**. Contact: your name, phone and email.

## 8. Archive and upload from Xcode

Do this once for iPhone/iPad and once for Mac.

1. In Xcode, select the **Kuki** target › **General**. Make sure **Version** is `1.0` and **Build** is `1`. Raise the Build number for every new upload.
2. **iPhone/iPad:**
   1. Choose **Any iOS Device (arm64)** as the destination.
   2. Choose **Product › Archive**.
   3. In the Organizer, choose **Distribute App › App Store Connect › Upload**, then keep **Automatically manage signing**.
3. **Mac:** choose **Any Mac (Mac Catalyst)** as the destination, then **Product › Archive** and **Distribute App › App Store Connect › Upload**. The menu bar plug-in and the widget are inside and get signed automatically.
4. Wait about 10–30 minutes for "Processing" to finish in App Store Connect (**TestFlight** tab).

If an upload is rejected for a missing icon size or similar, send me the message.

## 9. TestFlight first (recommended)

1. In **TestFlight**, add yourself under **Internal Testing**.
2. Install **TestFlight** on your iPhone, then install Kūki from it.
3. Check:
   - the real sensor
   - iCloud sync: the Mac in Station Mode → the iPhone widget follows
   - the wind-chime notification
   - the Live Activity

   This is the first time the Production iCloud environment and the release push setup are used, so it's the real end-to-end test.

## 10. Submit

1. **App Store** tab › iOS version 1.0 › attach the processed **Build** › fill in the screenshots and text › **Add for Review**.
2. Do the same for the **macOS** version.
3. Click **Submit for Review**. You'll get an email when it's done. Choose **Manually release** if you want to pick the launch day.

## Common rejection reasons for an app like this

- **4.2 / 2.1 "app doesn't work":** the reviewer couldn't see data. The Demo sensor note above prevents this.
- **5.1.1 Privacy:** the HomeKit permission text must say why. Ours does: *"Kūki reads the CO₂, temperature, humidity and particle levels from your air quality sensor in Apple Home."*
- **2.5.4 Background modes:** we declare `remote-notification` for the iCloud wake-ups. If asked, explain: "silent CloudKit pushes refresh the widget and Live Activity with the latest reading from the user's own devices."
- **5.2 Trademarks:** see section 5.
