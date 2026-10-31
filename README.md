# MyMob iOS app

SwiftUI prototype for MyMob, an Elder-governed community app (datathon build). It talks to the
Next.js server in the sibling `server/` repo; the API contract is `server/docs/API.md`.

## Run

- Xcode 27.1, iOS 27 simulator or device. Open `DatathonApp/DatathonApp.xcodeproj`, scheme `DatathonApp`.
- Server: `http://localhost:3000` by default. Change it in **Me → Settings → Server** (use the Mac's
  LAN address when running on a device).
- Demo phones accept OTP `123456`: `+61400000001` Aunty Grace (Elder, Saltbush Creek),
  `+61400000002` Uncle Tom (Elder, Ironbark Ridge), `+61400000003` Jordan (new member, join code
  `SALT-2026`), `+61400000004` Leah (patient), `+61400000005` Sam (Leah's carer). The sign-in screen
  has a "Demo accounts" shortcut list.

```sh
xcodebuild -project DatathonApp/DatathonApp.xcodeproj -scheme DatathonApp \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`DatathonAppTests` covers API decoding and the offline write queue; `LiveServerTests` and
`DatathonAppUITests` need the dev server running and use seeded accounts without changing demo data
(the UI test signs in as Aunty Grace and only browses).

## Demo flow A (Elder governance, one phone)

1. **Add a person** → Jordan → code → choose PIN → Community **+** → join code `SALT-2026` →
   "Waiting for approval".
2. **Me → Switch person → Add a person** → Aunty Grace → Saltbush Creek → shield icon (**Elder review**)
   → Join requests → **Approve**.
3. Switch to Jordan → Saltbush Creek → **What's on your mind?** → **Post**. It's live straight away.
   Switch to Grace → the post's **•••** menu → **Pin to top** (or **Remove post**).
4. Grace → Elder review → Clinic and service access → **Approve**.

## Demo flow B (clinic to patient)

- Leah signs in; clinic invites show at the top of **Calendar** → **Accept**. Push taps open Calendar.
- Sam (second device) sees Leah's appointment under **Calendar → Caring for**.
- Offline confirm: airplane mode (or **Settings → Developer → Simulate offline** in the simulator) →
  open the appointment → **Confirm I'll attend** → "Saved on this phone" → reconnect → it syncs
  (see **Me → Waiting to send**).
- Satellite beat: **Settings → Developer → Force satellite mode** → banner "Satellite mode: essentials
  only" → confirm → **Network log** shows `POST /api/sync/lite` with payload and gzip bytes.

## Design notes

- Post and comment reaction menus include Like, Heart, Thinking of you, Deadly
  (spear), and an Aboriginal flag custom icon. Touch and hold the reaction button
  to open the horizontal reaction picker; tap an icon to choose or clear it. VoiceOver exposes the same choices as actions. Deploy the server's
  `20261031010000_add_reactions` migration and updated API before using the new reactions.

- Offline-first: SwiftData caches feed, events, appointments, comments and carers per profile.
  Writes (`rsvp`, `confirmAppointment`, `createPost`, `createComment`, `reaction`) go into a
  `PendingMutation` queue with a fixed `clientMutationId` and flush through `POST /api/sync`.
- Satellite mode: real `NWPath.isUltraConstrained` or the developer toggle. Only `/api/sync/lite`
  runs, on a dedicated `URLSession` with `allowsUltraConstrainedNetworkAccess = true`; every other
  session leaves it off. No images, no extra fetches, no polling.
- Multi-profile: each person has a bearer token and a salted PIN hash in the Keychain; the app locks
  to the profile switcher on launch and whenever it goes to the background.
- Community languages: Settings → Language lists English plus every language communities have
  published on the server (and drafts for the people writing them). Choosing one downloads its
  approved strings (`GET /api/i18n/:code?platform=ios`) before switching, caches them on disk so
  they work offline and in satellite mode (never downloaded over satellite), and overlays them on
  the built-in English, so untranslated strings stay English. Translations are written and approved
  by each community at the server's `/languages` editor (see the server README).
  `App/CommunityLanguages.swift` routes `Bundle.main` lookups (including SwiftUI's) to the downloaded
  strings; app code that formats strings itself uses `localizedString(_:locale:)`.
  SHORTCUT: some of those lookups are private Foundation methods; fine for the datathon, but swap
  for a reviewed approach before App Store submission.
- After adding or changing user-facing text, add it to `Localizable.xcstrings` (Xcode does this on
  build) and run `node scripts/sync-ios-strings.mjs` in the server repo so communities can translate it.
- `Localizable.xcstrings` also keeps a built-in pseudo-translated placeholder ("Demo language
  (placeholder)", stored under the `fr` locale) that works without a server. Neither demo language
  is a real language.
- Neutral visual design; no Aboriginal or Torres Strait Islander art or symbols.
