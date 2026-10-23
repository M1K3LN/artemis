# Artemis: project handoff

Artemis shows a parent where their own children are on a heads-up display. The main target is Meta Ray-Ban Display glasses; a Meta Quest headset is a secondary target. Each child carries a device that deliberately shares its location: an Apple Watch (cellular) or a phone. Artemis uses no cameras and no face recognition. It only shows children whose devices joined with the family code.

This file brings a new Claude Code session up to speed. The project was built in a claude.ai chat that couldn't compile Swift or reach real hardware. Testing on the hardware is the next step.

## Ground rules

- **Personal side project of Mike's.** Keep it separate from his employer (alltreat.io). Do not use any work accounts, connectors, or infrastructure for Artemis, such as Vercel, Supabase, or HubSpot, unless Mike explicitly confirms they're personal. Use personal GitHub, Apple, and hosting accounts.
- **Current phase: proof of concept.** Keep things simple. Hardware v2 ideas (see Roadmap) are out of scope until the PoC proves out.
- **Formerly named "KinSight."** Rename any leftovers to Artemis. The name was chosen knowingly despite reports that "Artemis" is the codename of Meta's planned 2027 AR glasses. Possible trademark confusion was flagged to Mike and he accepted it.

## Test hardware

- 3 Apple Watches (cellular) worn by the kids
- Meta Ray-Ban Display glasses with the Neural Band, worn by the parent; they're paired to his iPhone, which supplies GPS
- A Mac running Xcode (the server is hosted on Render; see Running it)

## Architecture

```
Apple Watch app ──HTTPS POST /api/loc (every 15 s)──┐
child.html (phone) ──WebSocket──────────────────────┤
                                                    ▼
                                    server.js (Node, in-memory relay, no storage)
                                                    │ WebSocket
                         ┌──────────────────────────┴───────────────┐
              glasses.html?lens=1 (Ray-Ban Display)   phone.html (iPhone)   parent.html / glasses.html (Quest)
```

### Files
| File | What it is |
|---|---|
| `server.js` | Serves `public/` and relays locations. Supports WebSocket for phones and parents, and `POST /api/loc` for watches. Holds state only in memory; no database. Optional TLS via `TLS_CERT`/`TLS_KEY`. |
| `public/glasses.html` | Main parent view. `?lens=1` draws only the 600×600 lens UI on black for Ray-Ban Display. `?lens=1&family=CODE` connects live. Without `lens=1` it's a simulator: a three.js park with the lens overlay, a "Display glasses" vs "AR glasses (2027 concept)" toggle, and Quest WebXR. |
| `public/phone.html` | Parent view for a phone: list of kids with distance and arrow, alert banner with chime and vibration, Find screen, safe-zone slider, a demo mode, and compass arrows on iPhone (`webkitCompassHeading`) after tapping Compass. Same WebSocket protocol and alert rules as the glasses. Built so glasses are optional: the phone is the base product, the glasses are the upgrade. |
| `public/parent.html` | Original full HUD for Quest: 3D beams over each child, radar, and an alert banner. |
| `public/child.html` | Sharing page for a phone: name, family code, Start/Stop sharing. |
| `public/install.html` | Generates the Ray-Ban Display install QR code: `fb-viewapp://web_app_deep_link?appName=…&appUrl=…`. |
| `watch/ArtemisWatchApp.swift` | Single-file SwiftUI watchOS app: location sharing plus the watch-off check. **Never compiled yet.** |
| `README.md` | User-facing setup notes. |

### Message protocol
- **Family code:** `^[A-Z0-9]{8,16}$`, uppercase.
- **WebSocket join:** `{type:'join', role:'parent'|'child', family, id?, name?}` → server replies `{type:'joined', role, parentsOnline?}`.
- **Child to server:** `{type:'loc', lat, lon, acc, battery}`, rate-limited to one every 500 ms.
- **Watch to server:** `POST /api/loc` with JSON `{family, id, name, lat, lon, acc, battery, wrist:'on'|'off', wristTs}`. Rate-limited to one per 2 s per device, otherwise 429. Responds `{ok:true, parentsOnline}`.
- **Server to parents:** `hello {id,name}`, `loc {id,name,lat,lon,acc,battery,wrist,wristTs,ts}`, `left {id}`.
- **Clearing old data:** watch devices that stop posting are removed after 10 minutes. A phone is removed as soon as its socket closes.
- **Parent-side alerts:** outside the safe zone (default 40 m, adjustable); stale data (no update for 30 s, shown as "signal lost"); `wrist === 'off'` (shown as "watch may be off").

### Glasses lens UI (`glasses.html?lens=1`)
- **Three views.** Glance lists up to 4 kids with distance and an arrow. Alert takes over the screen with a chime when a kid needs attention. Find shows one kid with a big arrow and the distance.
- **Input, per Meta's Web Apps docs.** The touchpad and Neural Band send `keydown` events: arrow keys and `Enter`. Back is handled by the glasses' shell, which calls `history.back()`.
  - Enter: opens Find, or moves to the next kid; it also requests sensor permission the first time.
  - Arrow keys: switch kids in Find, or dismiss an alert.
  - Find and Alert push a history entry, so Back returns to Glance.
  - The lens canvas has `tabindex=0` and takes focus on load.
- **Heading:** `DeviceOrientationEvent.requestPermission()` is called from the first Enter. The app then listens to `deviceorientationabsolute`, falling back to `deviceorientation`, and only uses `absolute === true` values. Without a heading, directions are north-up ("To the north-east").
- **Location:** `navigator.geolocation.watchPosition`. On the glasses, the position comes from the paired phone.
- **Rendering:** black means see-through, so the lens is drawn additively.

### Watch app (`ArtemisWatchApp.swift`)
- Sends a POST every 15 s using CoreLocation with background location updates. Includes battery level.
- **Watch-off check:** keeps a running HKWorkoutSession only to get frequent heart-rate samples, plus the CoreMotion accelerometer. If there's no heart-rate sample and no movement for 60 s, it reports `wrist:'off'`. **Heart-rate values never leave the watch**; only on/off and the last time it was confirmed on the wrist are sent. The workout is discarded on stop and nothing is saved to Health.
- **Setup:** Info keys `NSLocationWhenInUseUsageDescription`, `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`. Capabilities: HealthKit, and Background Modes with Location updates and Workout processing. `serverURL` is set to `https://artemis-gqvn.onrender.com/api/loc`.
- **Risk:** App Review may reject a workout session used this way. That's fine for testing.

## Running it
**Hosted (default for testing):** the GitHub repo `M1K3LN/artemis` (private, personal account) deploys to Render's free tier via `render.yaml` and redeploys on every push to `main`. The URL is fixed (`https://artemis-gqvn.onrender.com`), so the watch `serverURL` and the glasses install don't change. The free tier sleeps after 15 min with no traffic and takes about a minute to wake.

**Local (fallback):**
```bash
npm install && npm start                          # http://localhost:8080
cloudflared tunnel --url http://localhost:8080   # gives the public HTTPS URL
```
- Ray-Ban Display needs Meta AI app v272+ and glasses software v125+. Turn on Developer Mode: in the Meta AI app, Settings → App Info, tap the version number five times. Install from `https://artemis-gqvn.onrender.com/install.html` by scanning the QR code with the glasses, or add the URL under Web Apps in the Meta AI app. HTTPS is required.
- **Watches:** create an Xcode project (watchOS → App → Watch-only, SwiftUI) named Artemis, replace the generated files with `ArtemisWatchApp.swift`, and add the capabilities and Info keys. Build in the Watch simulator first, then on each watch via its paired iPhone, with Developer Mode on for both.
- **Local fallback only:** the free tunnel URL changes on every restart. When it does, rebuild the watch app with the new `serverURL` and reinstall the glasses web app. Keep the tunnel running for the whole test.

## Status

**Tested in the cloud sandbox:**
- The server relay end to end (WebSocket, and POST → parent, including the `wrist` field)
- The rate limits
- That path traversal is blocked
- JS syntax of every page
- The lens UI in headless Chromium: Enter, arrows, and Back with no errors

**Fixed after handoff:** the watch and the phone page sent a position only when the device moved, so a child standing still (or a watch left on a bench) showed as "signal lost" after 30 s. Both now resend the last fix on a heartbeat (watch every 15 s, phone every 10 s).

**Phone parent view (`phone.html`):** tested in headless Chromium: demo, live connect, distances (20 m and 60 m test points), watch-off and left-the-zone alerts, signal lost at 30 s, Find and Back. Not yet tried on a real iPhone (compass permission, chime after a tap, screen wake lock).

**Not yet done or verified:**
1. **The Swift code has never been compiled.** Expect small fixes.
2. Nothing has run on real Ray-Ban Display glasses. Confirm that a Neural Band pinch arrives as `Enter` and a swipe as arrow keys, that Back works, and whether the compass permission prompt appears and `absolute` heading data arrives.
3. HealthKit capability on a free Apple ID: unknown. The $99 Apple Developer Program may be needed. Free-account builds expire after 7 days.
4. Watches set up through Family Setup may not accept direct Xcode installs; TestFlight may be needed. The easiest route is pairing the test watches to an iPhone Mike controls.
5. Watch battery life with GPS, cellular, and a workout session running.
6. Meta's docs push web apps toward their UI Toolkit (`@wearables-ui-toolkit/mrbd`, React + Vite) and the starter kit at github.com/facebook/meta-wearables-webapp. Rebuilding the lens UI with it is optional; consider it if canvas plus keydown proves unreliable.

## PoC test plan (what counts as success)
1. **End to end:** a watch's position shows on the glasses within a few seconds.
2. **Accuracy:** stand 10, 25, and 50 m apart and log what's displayed against the actual distance. Target: within about 10 m.
3. **Safe-zone alert:** a kid walks out of the zone and the alert fires within about 15 s, every time.
4. **Watch-off alert:** a watch left on a bench alerts within about 75 s.
5. **Signal lost:** a watch in airplane mode shows "signal lost" within about 30 s.
6. **Usefulness:** time how long it takes to find a kid in a crowd with the glasses, with `phone.html`, and with Find My. The glasses only earn their price if they clearly beat the phone.
7. **Endurance:** a 1–2 hour outing; record battery drain, dropouts, and how well the arrows point.

Offered but not built: a test-log mode that records displayed versus actual distance and alert timings.

## Decisions and why
- **4G tag, not AirTags or Tile:** there's no third-party API for live location. Kids' smartwatches like Gabb and TickTalk are closed ecosystems.
- **Watch POSTs instead of a WebSocket:** watchOS restricts long-lived sockets.
- **Heart rate is used only as an on-wrist signal.** Sending heart-rate values was rejected: they're noisy for safety use, they're health data about children (COPPA / App Review), and they'd change how the product comes across. A child-triggered SOS button is a better future feature.
- **Not Vercel for the server:** its serverless functions can't hold the parents' WebSocket connections. For hosting after the PoC, use Render, Railway, or Fly.io, which run `server.js` as is. Supabase Realtime plus accounts is a possible v2 replacement for the relay.
- **Privacy:** no persistence, positions are dropped on disconnect, and sharing is visible and stoppable on the child's device. Before anyone outside the family uses it: real accounts, per-device tokens, TLS everywhere, and a COPPA review.

## Roadmap (v2, after the PoC proves out)
- **Kid tag combining 4G GPS and UWB** (prototype: Nordic nRF91 plus Qorvo DWM3001C). 4G handles distance; UWB gives about a foot of accuracy within roughly 30–50 m.
- **Native parent iPhone app.** It would combine UWB via Apple's Nearby Interaction framework with server GPS and drive the glasses through Meta's Wearables Device Access Toolkit (native SDK). Web apps can't use UWB. Open question: UWB direction is relative to the phone, not the head.
- **Cheaper alternative to watches:** 4G GPS trackers that speak the GT06 or OsmAnd protocol (about $25–60 plus a $3–10/month SIM), with dual-frequency L1/L5 for better accuracy. This needs a protocol adapter on the server, or Traccar in front of it.
- **2027 Meta AR glasses:** the "AR glasses" profile in `glasses.html` is a design study for world-locked markers.

## Reference
- Meta Web Apps docs: https://wearables.developer.meta.com/docs/develop/webapps/ (subpages: setup, input-and-navigation, sensors-and-location, test)
- Meta FAQ: https://developers.meta.com/wearables/faq/
