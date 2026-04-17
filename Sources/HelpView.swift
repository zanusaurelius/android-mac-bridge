import SwiftUI

// MARK: - Full setup guide, shown both in the no-device screen and via the ? sheet

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                Text("Setup Guide")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 4)

                Text("Follow these steps to connect your Android phone and browse files.")
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)

                gatekeeperNote
                    .padding(.bottom, 20)

                stepList

                Divider().padding(.vertical, 20)

                troubleshooting
            }
            .padding(24)
        }
    }

    // MARK: - macOS first-launch warning

    private var gatekeeperNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("First time opening this app", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))

            Text("macOS may say **\"can't be opened because it is from an unidentified developer\"**. This is normal for apps not sold through the Mac App Store.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Label("Right-click (or Control-click) the app icon", systemImage: "1.circle.fill")
                Label("Choose **Open** from the menu", systemImage: "2.circle.fill")
                Label("Click **Open** in the dialog that appears", systemImage: "3.circle.fill")
            }
            .font(.callout)
            .foregroundColor(.secondary)

            Text("You only need to do this once.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        .cornerRadius(8)
    }

    // MARK: Steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(
                number: 1,
                icon: "hammer.fill",
                title: "Enable Developer Options",
                detail: "Open **Settings → About Phone** and tap **Build Number** seven times in a row. You'll see a message saying \"You are now a developer!\" Enter your PIN if prompted.",
                note: "Location varies by brand:\n• Samsung — Settings → About Phone → Software Information → Build Number\n• Pixel — Settings → About Phone → Build Number\n• OnePlus — Settings → About Device → Version → Build Number\n• Xiaomi / Redmi — Settings → About Phone → All Specs → MIUI Version"
            )

            SetupStep(
                number: 2,
                icon: "switch.2",
                title: "Turn On USB Debugging",
                detail: "Go to **Settings → Developer Options** (sometimes under Additional Settings) and toggle **USB Debugging** on. Tap OK to confirm.",
                note: nil
            )

            SetupStep(
                number: 3,
                icon: "cable.connector",
                title: "Connect with a Data Cable",
                detail: "Use a USB cable that supports **data transfer** — charge-only cables won't work. Plug it into your Mac.",
                note: "If you're unsure, try a different cable. Many cables included with chargers are charge-only."
            )

            SetupStep(
                number: 4,
                icon: "iphone",
                title: "Set USB Mode to File Transfer",
                detail: "A notification will appear on your phone's lock screen or in the notification shade asking how to use the USB connection. Tap it and choose **File Transfer** or **MTP**.",
                note: "If you see only \"Charging\" — pull down your notification shade and tap the USB connection entry to change the mode."
            )

            SetupStep(
                number: 5,
                icon: "checkmark.shield.fill",
                title: "Allow USB Debugging",
                detail: "A popup will appear on your phone: **\"Allow USB debugging?\"** Tap **Allow**. Check **\"Always allow from this computer\"** so you won't be prompted again.",
                note: nil
            )

            SetupStep(
                number: 6,
                icon: "app.connected.to.app.below.fill",
                title: "App Connects Automatically",
                detail: "This app checks for your device every two seconds. Once it detects your phone, your files will appear automatically — no button to press.",
                note: nil
            )
        }
    }

    // MARK: Troubleshooting

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Troubleshooting", systemImage: "wrench.and.screwdriver.fill")
                .font(.headline)
                .padding(.bottom, 2)

            TipRow(icon: "cable.connector.slash",
                   text: "Nothing showing up? Try a different cable — many cables are charge-only and won't carry data.")

            TipRow(icon: "lock.open",
                   text: "Keep your phone screen unlocked. Some phones block file access when locked.")

            TipRow(icon: "arrow.counterclockwise",
                   text: "Still not working? Go to Developer Options → Revoke USB Debugging Authorizations, unplug, replug, and allow again.")

            TipRow(icon: "exclamationmark.triangle",
                   text: "On some Samsung phones you may also need to disable MIUI optimizations (Xiaomi) for ADB to work fully.")
        }
    }
}

// MARK: - Step row

private struct SetupStep: View {
    let number: Int
    let icon: String
    let title: String
    let detail: String
    let note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Numbered circle
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold))

                FormattedText(detail)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)
                }
            }
        }
    }
}

// MARK: - Tip row

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundColor(.secondary)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Bold-in-plain-text helper
// Renders text where **word** becomes bold via AttributedString.

private struct FormattedText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let parts = raw.components(separatedBy: "**")
        for (index, part) in parts.enumerated() {
            var segment = AttributedString(part)
            if index % 2 == 1 {
                segment.font = .callout.bold()
            }
            result.append(segment)
        }
        return result
    }
}
