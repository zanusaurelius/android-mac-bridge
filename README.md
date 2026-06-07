# Android Mac Bridge

A native macOS app for transferring files between your Android phone and Mac over USB in both directions. No accounts, no cloud, and no more unreliable android transfer apps.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## Install

1. Download **AndroidMacBridge.dmg** from the [Releases](../../releases) page
2. Open the DMG and drag **AndroidMacBridge** into your **Applications** folder
3. **First launch only:** right-click the app → **Open** → **Open**
   > macOS warns you it's from an unidentified developer because the app isn't sold through the App Store. Right-clicking and choosing Open lets you bypass this — you only need to do it once.

---

## How it works

The app uses **ADB (Android Debug Bridge)** — Google's official tool for communicating with Android devices — which is bundled inside the app so you don't need to install anything separately.

Once your phone is connected with USB debugging enabled, the app talks directly to your phone over USB. No internet connection is used. Your files never leave your local network.

**Mac → Android:** Drag any file from your Mac desktop or Finder window into the app and it's copied to your phone.

**Android → Mac:** Select files in the app and drag them to your Mac desktop, a Finder window, or any app that accepts files.

---

## Connect your phone

### 1 — Enable Developer Options
Go to **Settings → About Phone** and tap **Build Number** seven times. You'll see "You are now a developer!"

> Location varies by brand:
> - **Samsung** → Settings → About Phone → Software Information → Build Number
> - **Pixel** → Settings → About Phone → Build Number
> - **OnePlus** → Settings → About Device → Version → Build Number
> - **Xiaomi** → Settings → About Phone → All Specs → MIUI Version

### 2 — Turn on USB Debugging
Go to **Settings → Developer Options** and toggle **USB Debugging** on.

### 3 — Use a data cable
Plug your phone into your Mac with a cable that supports **data transfer**. Many charger cables are charge-only — try a different one if nothing happens.

### 4 — Set USB mode to File Transfer
A notification will appear on your phone. Tap it and choose **File Transfer** or **MTP**.

### 5 — Allow USB Debugging
A dialog will appear on your phone asking **"Allow USB debugging?"** — tap **Allow**. Check "Always allow from this computer" so you won't be asked again.

### 6 — Done
The app detects your phone automatically and your files appear. No button to press.

---

## Features

- **Browse** your Android file system in list or thumbnail view
- **Expand folders inline** without navigating away
- **Android → Mac:** drag files out to your desktop or any Finder window
- **Mac → Android:** drag files from your Mac into the app
- **Spacebar preview** (Quick Look) for photos and videos
- Sort by name, date, or size
- Show or hide hidden files

<img width="982" height="706" alt="Screenshot 2026-06-06 at 9 37 41 PM" src="https://github.com/user-attachments/assets/b5499f5c-9a17-4117-8f1b-293201512fe8" />
<img width="982" height="708" alt="Screenshot 2026-06-06 at 9 38 35 PM" src="https://github.com/user-attachments/assets/3cb8cc63-3f5c-4721-b17c-9db99099f49c" />

---

## Troubleshooting

**Nothing shows up after connecting**
- Try a different USB cable — most charger cables don't carry data
- Make sure USB mode on your phone is set to File Transfer, not Charging
- Keep your phone screen unlocked — some phones block access when locked

**"Allow USB debugging" dialog won't appear**
- Go to Developer Options → **Revoke USB Debugging Authorizations**, unplug, replug, and try again

**App says no device connected**
- Unplug and replug the cable
- Try a different USB port on your Mac

---

## Build from source

Requires macOS 14+, Xcode Command Line Tools, and `adb` installed via Homebrew.

```bash
brew install android-platform-tools
bash build.sh
```

The script compiles the app, bundles `adb` inside it, and produces `build/AndroidMacBridge.dmg`.

---

## Licence

MIT — free to use, modify, and share. See [LICENSE](LICENSE).
