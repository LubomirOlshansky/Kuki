# Kūki — Privacy Policy

*Last updated: 14 November 2026*

Kūki reads the air-quality values of sensors you have added to Apple Home and shows and records them **on your own devices**.

## What Kūki collects

Usage statistics, tied to a random identifier for your device, so the developer can see how many people use Kūki and which features they use. They are sent to [Amplitude](https://amplitude.com), an analytics service, and stored in its **EU data centre**. They consist of:

- which features are used (for example: History opened, an export made, Station Mode started, a setting changed), and counts such as how many places you have or how many readings this device recorded in a day;
- the kind of device and its operating system (iPhone, iPad or Mac, and the OS version), and the app version;
- your approximate location (country and city), derived by Amplitude from the IP address the statistics arrive from;
- a random device identifier (Apple's identifier for vendor), so one device counts once. It is not your advertising identifier.

These statistics are tied to a random identifier for your device, so Apple's privacy label lists them as **linked to you**. Kūki still has no account and never sends your name, email or Apple Account. They are **not used to track you** across other companies' apps or websites, and are never sold or used for advertising. They **never include your readings** (no CO₂, temperature, humidity or PM2.5 values — only broad levels such as "stuffy"), and **never any names**: not your places, rooms, sensors or homes, nor the contents of your exports or anything from your iCloud.

**To turn it off:** Settings › Privacy › *Share usage data* (on the Mac: Kūki › Settings…). When it is off, Kūki sends nothing at all, not even a note that you turned it off. It is on by default.

There is no other analytics, no advertising and no tracking in Kūki.

## What stays on your device

- Readings from your sensors (CO₂, temperature, humidity, PM2.5), with the time and the place you assigned.
- Your places and settings.

They are stored only on the device where Kūki recorded them. You can export them yourself (CSV or Markdown) and delete them at any time in Settings › Data.

## Apple Home (HomeKit)

Kūki asks for permission to access your Home data so it can read your air sensors. It only reads sensor values; it never changes your accessories, and Home data is never sent anywhere by Kūki.

## iCloud (optional)

If iCloud Sync is on (Settings › iCloud Sync), Kūki keeps in **your private iCloud database**:

- the latest reading and its place name, so your other devices' widgets, Lock Screen and alerts can show it;
- the history each of your devices records (readings grouped by hour), your list of places, and which place the sensor is in, so all your devices show the same history.

This data is stored by Apple under your Apple Account; the developer cannot access it. Turn iCloud Sync off at any time to stop it; what is already in iCloud stays there until you remove it (Settings › Apple Account › iCloud › Manage Storage).

## Notifications

If you turn them on, Kūki shows local notifications when CO₂ crosses your limit. No push service of the developer is involved.

## Contact

Questions: open an issue at https://github.com/LubomirOlshansky/Kuki/issues
