# Sparkle auto-update — drop-in guide

Everything is staged so turning on auto-updates is a bounded, ordered task once
the app is **notarized** (Sparkle refuses to update a non–Developer-ID app) and
you have somewhere to **host** the feed. The live updater code is intentionally
not wired yet — it can't be verified without a notarized build + a hosted feed,
so shipping it blind would be untested machinery.

Prerequisites (see `docs/plans` / `onyx-scribe-commercial`): Apple Developer
enrollment, Developer ID signing (already handled by `scripts/build-app.sh` when
the cert exists), and a static host for `web/appcast.xml` + the DMGs.

## 1. Generate the EdDSA signing key (once)
Sparkle ships `generate_keys`. Run it once; it stores the **private** key in your
login keychain and prints the **public** key.
```
./bin/generate_keys              # from the Sparkle distribution
# → prints:  SUPublicEDKey  <base64>
```
Keep the private key secret (like the license key in `~/.flowclone/signing-key.b64`).

## 2. Add Sparkle to the package
In `FlowClone/Package.swift`:
```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
// …and in the FlowClone target dependencies:
.product(name: "Sparkle", package: "Sparkle"),
```

## 3. Info.plist keys (`FlowClone/Support/Info.plist`)
```xml
<key>SUFeedURL</key>        <string>https://onyxscribe.app/appcast.xml</string>
<key>SUPublicEDKey</key>    <string><!-- the base64 from step 1 --></string>
<key>SUEnableAutomaticChecks</key> <true/>
<key>SUScheduledCheckInterval</key> <integer>86400</integer>
```

## 4. Wire the updater
The app is a menu-bar `NSApplication` (accessory). Add a standard updater and a
"Check for Updates…" menu item. Suggested new file `FlowClone/Sources/FlowClone/Updater.swift`:
```swift
import Sparkle

/// Thin wrapper over Sparkle's standard updater. Menu-bar app: no UI beyond the
/// update dialog Sparkle drives. Never sends dictation data — it only fetches the
/// signed appcast and DMG. Disclose this on the site's privacy line.
final class Updater {
    static let shared = Updater()
    let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
```
In `AppDelegate.buildMenu()` add:
```swift
menu.addItem(NSMenuItem(title: "Check for Updates…",
                        action: #selector(checkForUpdates), keyEquivalent: ""))
// and:
@objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
```
Touch `Updater.shared` once at launch (e.g. in `applicationDidFinishLaunching`)
so the scheduled background check starts.

## 5. Cut a release
1. Bump `CFBundleVersion` (integer, e.g. 101) and `CFBundleShortVersionString`
   (e.g. 1.0.1) in `Support/Info.plist`.
2. `./scripts/build-app.sh` with the Developer ID cert present, then notarize
   (`NOTARY_PROFILE=…` — the script's notarize+staple step handles it).
3. Package the stapled `.app` into a DMG (e.g. `create-dmg`).
4. Sign it: `./bin/sign_update OnyxScribe-1.0.1.dmg` → prints `edSignature` + length.
5. Fill in a new `<item>` in `web/appcast.xml` (uncomment the template) with the
   version, URL, `edSignature`, and `length`. Deploy `appcast.xml` + the DMG.

Sparkle clients poll `SUFeedURL`, verify the EdDSA signature against
`SUPublicEDKey`, and offer the update. Because it's signature-gated, a
compromised host still can't push a malicious update without your private key.

## Privacy note
Update checks are the app's **only** outbound network calls besides an explicit
license refresh. They send no dictation audio or text. Keep the site's "no
servers for your voice" claim accurate by disclosing the update check.
