# Artemis

A heads-up display for a parent wearing an AR/VR headset. Each of your children carries a phone running the Artemis sharing page; the headset shows a marker over where each child is, their distance and direction, a radar, and an alert when a child leaves the safe zone or their phone stops reporting.

It only shows children whose phones were deliberately paired with your family code. It does not use cameras or recognise anyone.

## How it fits together

```
child phone (child.html) --GPS over WebSocket--> server.js --relay--> headset (parent.html)
```

- `public/parent.html` — the HUD. three.js + WebXR. Uses passthrough AR when the headset supports it (e.g. Meta Quest 3), otherwise VR.
- `public/child.html` — opt-in sharing page with a visible "Sharing" state and a Stop button.
- `server.js` — serves both pages and relays positions. Nothing is stored; a child's last position is dropped when they disconnect.

## Run it

```bash
npm install
npm start            # http://localhost:8080
```

Headsets and phones only allow location and WebXR on **HTTPS**. For real use either:

- pass a certificate: `TLS_CERT=cert.pem TLS_KEY=key.pem npm start`, or
- put it behind an HTTPS tunnel (e.g. Cloudflare Tunnel or ngrok) and use that URL on every device.

## Use it

1. On the headset, open `https://<your-host>/parent.html`, choose **Live**, press **New code**, then **Connect**.
2. On each child's phone, open the link shown in the status line (`/child.html?family=CODE`), enter a name, and tap **Start sharing**.
3. Face north and press **Set north** (in the headset, squeeze the controller grip). Headsets don't have a compass, so this lines the markers up with the real world.
4. Press **Enter AR / VR**. The HUD panel stays below your line of sight; markers float over each child.

**Demo** mode needs no server or phones and simulates three kids.

## Glasses view (`/glasses.html`)

Previews Artemis on Meta's display glasses, in a simulated park or in a Quest headset.

- **Display glasses** — matches Ray-Ban Display: a ~20° screen low in the right lens, no world markers. Three states: Glance (everyone), Alert (a child leaves the zone or loses signal), Find (one child, big arrow).
- **AR glasses (2027 concept)** — markers pinned over each child plus a card low in view. Meta's 2027 AR glasses are reported, not announced; treat this as a design study.
- **Gestures** — Pinch opens Find / cycles kids; Swipe dismisses. On screen: the Pinch and Swipe buttons or Enter / Esc. In a Quest: trigger = pinch, grip = swipe.
- **Black is see-through.** The lens is rendered additively, the way the real display works.
- **Lens-only mode for real glasses:** `/glasses.html?lens=1&family=CODE` draws just the 600×600 lens UI on black.

### Installing on Meta Ray-Ban Display

Requires Meta AI app v272+ and glasses software v125+ (Meta's current requirements).

1. Meta AI app → Settings → App Info → tap the version number five times → enable Developer Mode.
2. With the server and tunnel running, open `https://YOUR-TUNNEL/install.html` on your Mac, enter the family code, and press **Make install code**. Scan the QR code with the glasses and confirm. (Or add the printed address in the Meta AI app under Web Apps.)
3. Controls on the glasses: pinch/tap = select (opens Find, or the next child), swipe = previous/next child or dismiss an alert, Back = return to the overview.
4. The first pinch also asks for motion-sensor permission, which turns on head-direction arrows. Until then, directions are north-up ("To the north-east").

Location on the glasses comes from your paired phone, so keep the phone with you with location on.

## Apple Watch (cellular)

`watch/ArtemisWatchApp.swift` is a watchOS app for kids who carry a cellular Apple Watch instead of a phone. watchOS restricts WebSockets, so the watch POSTs to `/api/loc` every 15 seconds instead; parents see it exactly like a phone.

1. In Xcode, create a watchOS App, paste the file, and set `serverURL` to your public HTTPS address.
2. Add a location usage description and Background Modes > Location updates.
3. Install on a watch, enter the child's name and the family code, tap Start sharing.

**Watch-off check:** the watch reports "off" when it gets no heart-rate readings and no movement for 60 seconds, and the parent display shows "Ava's watch may be off" with the time it was last on her wrist. Only on/off and that time leave the watch — never heart-rate values. It needs HealthKit permission and a workout session for frequent readings (App Review may question this; fine for testing). A watch carried in a bag still moves, so it may read as "on".

Needs an Apple Developer account to install. For kids' watches set up through Family Setup, check Apple's current docs on installing development or TestFlight builds.

## Limits to know about

- Phone GPS is typically accurate to 5–20 m, worse near tall buildings and indoors. Treat markers as "roughly there", not exact.
- Browsers pause location when the sharing page is in the background or the screen locks. The page asks to keep the screen awake, but a native companion app is needed for reliable background sharing.
- North alignment drifts if the headset loses tracking; re-run Set north.
- Don't rely on this as the only safety measure.

## Before putting this in front of real families

- Replace the family code with proper accounts and per-device pairing tokens.
- Always serve over TLS; never log positions.
- Keep sharing visible and stoppable on the child's device (it is today — keep it that way).
- Review location-privacy rules where you'll operate (e.g. COPPA in the US, GDPR-K in the EU) if children's data passes through your servers.
