# Getting PocketFilm running on your iPhone 15 Plus

You need: your Mac, ~20 GB free disk space, a USB cable, and about an hour (mostly Xcode downloading). Everything is free.

## 1. Install Xcode (free)

1. On your Mac, open the **App Store** app, search **Xcode**, click **Get**. It's a big download (~10–15 GB) — let it finish.
   - Xcode 16 requires macOS Sonoma 14.5 or newer. If the App Store says your macOS is too old, update macOS first (Apple menu → System Settings → General → Software Update).
2. Launch Xcode once. It will ask to install additional components — say yes.

## 2. Get this code onto the Mac

Either clone with git:

```sh
git clone https://github.com/frankief93/terpmap.git
cd terpmap
git checkout claude/app-clone-no-paywall-37o53s
```

…or on GitHub, switch to the `claude/app-clone-no-paywall-37o53s` branch → green **Code** button → **Download ZIP**, and unzip it.

## 3. Open and sign the project

1. Double-click `ios/PocketFilm.xcodeproj`.
2. Xcode menu → **Settings… → Accounts** → **+** → **Apple ID** → sign in with your normal Apple ID (free — this creates a "Personal Team").
3. In the left sidebar click the blue **PocketFilm** project icon → select the **PocketFilm** target → **Signing & Capabilities** tab:
   - **Team**: pick your Personal Team.
   - **Bundle Identifier**: change `com.pocketfilm.camera` to something unique to you, e.g. `com.frankie.pocketfilm`.

## 4. Set up your iPhone

1. Plug the iPhone 15 Plus into the Mac with a cable. Unlock it and tap **Trust** when asked.
2. On the iPhone: **Settings → Privacy & Security → Developer Mode** → turn it **on** → restart the phone. (If you don't see Developer Mode yet, it appears after Xcode detects the phone once.)

## 5. Run it

1. In Xcode's toolbar (top center), click the device picker and choose your iPhone (not a simulator — the simulator has no camera).
2. Press the **▶ Run** button (or Cmd+R).
3. First run only: the app will fail to launch with a trust warning. On the iPhone go to **Settings → General → VPN & Device Management**, tap your Apple ID, tap **Trust**. Run again from Xcode.
4. Grant camera and Photos permissions when the app asks.

## Free-account fine print

- The app **expires after 7 days** — just plug in and press Run again to refresh it. (A paid Apple Developer account, $99/yr, extends this to 1 year and enables TestFlight/App Store.)
- Max 3 sideloaded apps at a time on a free account.

## When something goes wrong

That's expected on a first build — this code has never been compiled (it was written on a Linux machine with no Xcode). Copy the **exact error text** from Xcode (red icons in the left Issues panel, or the build log) and paste it back into the Claude session. Screenshots of the app misbehaving help too. Fix → push → you press Run again.

## If the project file itself won't open

Fallback that always works:

1. Xcode → **File → New → Project → iOS → App**. Name: `PocketFilm`, Interface: SwiftUI, Language: Swift.
2. Delete the generated `ContentView.swift`.
3. Drag all `.swift` files from this folder's `PocketFilm/` directory into the project navigator (check **Copy items if needed** and add to the PocketFilm target). Don't drag `Info.plist` or `PocketFilmApp.swift`'s duplicate — if Xcode complains about two `@main` entries, delete its generated `PocketFilmApp.swift` and keep ours.
4. Project → target → **Info** tab → add two keys:
   - *Privacy – Camera Usage Description*: "PocketFilm is a camera."
   - *Privacy – Photo Library Additions Usage Description*: "Saves your photos."
5. Sign and run as above.
