# Putting Kūki on the App Store

One app record covers **iPhone, iPad and Mac** (same bundle ID `com.olshanskysoft.kuki`, so it's one purchase on all three). Team `S6PVT5UP7G`.

Already done in the project:
- Privacy manifests (`Kuki/PrivacyInfo.xcprivacy`, `KukiWidget/PrivacyInfo.xcprivacy`): no tracking; the app declares Product Interaction, Device ID and Coarse Location, all for Analytics, linked to the user (device ID), not tracking (Amplitude); two required-reason APIs declared. The Amplitude-Swift package ships its own manifest, which Xcode bundles automatically.
- `ITSAppUsesNonExemptEncryption = NO`, so there's no export-compliance question at each upload.
- Release builds verified for iPhone and Mac: no debug switches inside.
- Privacy policy text: [`PRIVACY.md`](../PRIVACY.md).

Work through the steps in order. Rough time: an afternoon, plus Apple's review (usually 1–2 days).

---

## 1. Before anything: decide what Kūki promises

Apple Home only gives sensor values to an app that's active. On the **Mac**, Kūki stays active as a menu bar app (with an invisible keep-alive window), so it records 24/7. On **iPhone/iPad** it records only while open. Word it like this:

> On Mac, Kūki lives in the menu bar and records around the clock. On iPhone and iPad it records while open; Station Mode turns a spare device into a full-time monitor.

## 2. iCloud: deploy the data layout to Production (required)

The iCloud records Kūki uses exist only in the **Development** environment until you deploy them. App Store builds use **Production**, and without this step sync silently does nothing for real users.

| Record type | Zone | Fields |
|---|---|---|
| `LatestAir` | default | co2, temperature, humidity, pm25 (Double) · placeName, placeKanji (String) · measuredAt (Date) · recentCO2 (Double list) · limit (Double) |
| `HourChunk` | `KukiHistory` | deviceID, sensorName (String) · hourStart (Date) · payload (Bytes) |
| `Place` | `KukiHistory` | name, kanji, originDeviceID, mergedInto (String) · sortIndex, deleted (Int64) · modifiedAt, createdAt (Date) |
| `SensorState` | `KukiHistory` | currentPlaceID (String) · placeChangedAt (Date) |

1. Run a signed Debug build with iCloud Sync on until it has recorded a reading, moved the sensor once and added (or renamed) a place, so every record type and field exists in Development. `LatestAir` you've already done; the three history types are new.
2. Open **https://icloud.developer.apple.com** › **CloudKit Console** › container **iCloud.com.olshanskysoft.kuki**.
3. **Schema › Indexes:** for record type `LatestAir`, add a **Queryable** index on `recordName`. iCloud wake-up subscriptions need it. (The history types need no indexes: CKSyncEngine reads zone changes, not queries.)
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

**App Privacy** (the "nutrition label"): click **Get Started** › **"Yes, we collect data from this app"**, then declare exactly these three (Kūki sends usage statistics, linked to a random device ID, to Amplitude, EU data centre; readings stay on the user's devices and in the user's own private iCloud):

| Category › Data type | Purpose | Linked to the user? | Used for tracking? |
|---|---|---|---|
| Usage Data › **Product Interaction** | Analytics | Yes | No |
| Identifiers › **Device ID** | Analytics | Yes | No |
| Location › **Coarse Location** | Analytics | Yes | No |

- *Product Interaction*: which features are used (tabs, exports, Station Mode, settings), never readings or names.
- *Device ID*: Amplitude's device ID, the identifier for vendor. No IDFA, so no App Tracking Transparency prompt is needed.
- *Coarse Location*: Amplitude derives country and city from the IP address. Kūki never asks for Location Services.
- Linked: events carry a device ID, so they're declared linked (published 14 Nov 2026), although there's no account and no user ID. Not tracking: nothing is combined with other companies' data or used for advertising.

Nothing else is collected (no contact info, no health data, no sensor readings, no diagnostics). The answers must match `Kuki/PrivacyInfo.xcprivacy` and `PRIVACY.md`; change all three together.

## 5. Store text

**Description** (live in App Store Connect; iOS):

> Kūki (空気, "air") shows how fresh the air is in the room where your sensor sits, quietly.
>
> It works with air-quality sensors in Apple Home, such as the IKEA ALPSTUGA: CO₂, temperature, humidity and PM2.5.
>
> HOW IT RECORDS
> Apple Home gives an iPhone or iPad app new readings only while it is open, so on its own your iPhone records while Kūki is open. For around-the-clock data, run Kūki on a Mac, where it lives in the menu bar, or leave a spare iPhone or iPad in Station Mode. Your iPhone's widgets, Lock Screen and alerts then follow along through iCloud.
>
> • An ensō brush circle that grows with CO₂, and plain advice: clear air, fine, getting stale, stuffy.
> • Move the sensor between rooms and compare them: history per place, averages, peaks, time over your limit.
> • A soft wind-chime when it's time to open a window: while Kūki is open, and usually also while it is closed when a Mac or Station device is recording.
> • Widgets, Lock Screen and Live Activity show the latest reading; they stay current while a Mac or Station device records.
> • Export to CSV, or an AI-ready summary for Claude or ChatGPT.
>
> No account, no ads, no tracking: your readings stay on your devices and in your own iCloud. Usage statistics, linked only to a random device identifier, help improve Kūki; turn them off in Settings.

The macOS description leads with the menu bar and 24/7 recording instead of "How it records".

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

> Kūki reads air-quality sensors (e.g. IKEA ALPSTUGA) through HomeKit. No sensor needed: tap Skip, then Try the demo — or on 'How Kūki hears the air' choose 'No sensor yet? Try the demo'. Alternatively, open **Settings** (iPhone: Settings tab; Mac: Kūki › Settings… or ⌘,) and turn on **Demo sensor**. Optional: tap **Add 3 days of demo history** to see History and Export. HomeKit access is used only to read sensor values; nothing is controlled or sent anywhere. The optional airing reminder is a local notification at times the user picks; notification permission is asked only when it (or the CO₂ notification) is switched on. With iCloud Sync on, the user's recorded history, place list and latest reading sync between their own devices through their private iCloud database. Station Mode disables the idle timer only while it is shown. On the Mac, Kūki is a menu bar app that keeps a transparent 1-pt window so it stays active and HomeKit keeps delivering readings for continuous logging.

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
