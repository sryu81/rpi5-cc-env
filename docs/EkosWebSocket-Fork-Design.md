# EKOS WebSocket Fork — Architecture Trace & Design Plan

## Goal

Build a mobile app that controls Ekos (KStars' astrophotography automation module)
remotely over the network, similar in spirit to EkosLive. The Pi (running INDI + KStars,
built by this repo's `Makefile`) is the host; the mobile app is the remote client.

**Confirmed architecture (2026-07-27): the Pi listens, the phone connects directly.**
No middle relay/cloud server. Single primary phone; broadcast semantics (no per-client
targeting) are acceptable for now.

This requires forking KStars — stock KStars' existing remote-control feature (EkosLive)
cannot do this as-is (see below). Not started yet; this doc is the design reference for
when that work begins.

---

## Background: two separate protocol layers in KStars

### 1. Ekos ↔ INDI (device layer) — untouched by this work

- `indiserver` spawns one process per driver (`indi_simulator_ccd`, etc.), talking to
  each over stdin/stdout via the INDI protocol (XML-tagged property vectors, BLOBs for
  images). Exposes this over TCP (port 7624) to clients.
- `kstars/indi/clientmanager.h` — `ClientManager` subclasses `INDI::BaseClient`
  (from `libindiclient`) directly. Owns the TCP connection and raw property traffic.
- `kstars/indi/indilistener.h` — `INDIListener` turns raw INDI properties into KStars'
  internal device object model (`ISD::GDInterface` etc.), which Ekos modules
  (`kstars/ekos/{capture,focus,guide,align,mount,scheduler,...}`) consume.

Ekos never speaks raw INDI protocol itself — it's always through this layer. Nothing
here needs to change for the WebSocket fork.

### 2. Ekos ↔ remote client (EkosLive) — the reference implementation, and what needs replacing

Full existing implementation at `repo/kstars/kstars/ekos/ekoslive/`:

| File | Role |
|---|---|
| `node.h`/`node.cpp` | Thin wrapper around `QtWebSockets::QWebSocket`. Generic send/receive. |
| `nodemanager.h`/`.cpp` | Owns up to 3 `Node`s (Message/Media/Cloud channels) for one named server slot. HTTP auth handshake before opening any socket. |
| `ekosliveclient.h`/`.cpp` | Orchestrator (`EkosLive::Client`). Owns 2 `NodeManager`s (`Online`, `Offline`), wires `Message`/`Media`/`Cloud` to `Ekos::Manager`. |
| `message.h`/`.cpp` | The JSON protocol — per-module status pushes + generic RPC. **Reusable.** |
| `media.h`/`.cpp` | Separate channel for images/video frames. **Reusable.** |
| `cloud.h`/`.cpp` | Cloud-relay-specific channel. **Not needed.** |
| `commands.h` | Command name enum (`GET_CONNECTION`, `INVOKE_METHOD`, `SET_PROPERTY`, `GET_PROPERTY`, per-module `NEW_*_STATE`, etc). **Reusable.** |

---

## What was traced, and what it means

### `Node` is client-mode only

`node.cpp:40`, `Node::connectServer()`:
```cpp
m_WebSocket.open(requestURL);
```
Always dials *out*. No `QWebSocketServer`/listening capability anywhere in this class
or anything it calls. **This is the core reason a fork is required** — EkosLive's
entire architecture assumes KStars is the one initiating the connection to a server
it's told about, never the one accepting incoming connections.

### `NodeManager` requires an HTTP auth handshake before any socket opens

`nodemanager.cpp:147`, `NodeManager::authenticate()`:
```cpp
QUrl authURL(m_ServiceURL);
authURL.setPath("/api/authenticate");
QJsonObject json = {{"username", m_Username}, {"machine_id", KSUtils::getMachineID()}};
// ...password or device_token...
m_NetworkManager->post(request, postData);
```
Response expected: `{"success": true, "token": "<JWT>"}` (`KSUtils::getJwtExpiryTimestamp`
parses it). Only *after* this succeeds does `onResult()` call `node->connectServer()`
for each configured channel (`nodemanager.cpp:285-293`).

Note: `NodeManager`'s channel mask is already a bitfield (`Message | Media | Cloud`), and
`ekosliveclient.cpp:69` already constructs an "Offline" manager with `Message | Media`
(no `Cloud`) pointed at a user-configurable server URL (`Options::ekosLiveOfflineServer()`,
editable via `Client::showSelectServersDialog()`). So EkosLive already has a "bring your
own server" escape hatch — but it still requires implementing the `/api/authenticate`
contract, and still only dials out. Doesn't satisfy "Pi listens" on its own.

### `Message`/`Media` are reusable protocol code, not reusable transport code

Constructor (`message.cpp:49-79`) only wires two things directly to `Ekos::Manager`:
```cpp
connect(manager, &Ekos::Manager::newModule, this, &Message::sendModuleState);
connect(INDIListener::Instance(), &INDIListener::deviceRemoved, this, [...] {...});
```
The real per-module wiring lives in `Ekos::Manager` itself (`kstars/ekos/manager.cpp`),
which already connects to each module's own signals and calls straight into `Message`
inline, e.g. (`manager.cpp` ~2560-2600, focus example):
```cpp
connect(focusModule()->mainFocuser().get(), &Ekos::Focus::newFocusAdvisorMessage, this,
        [this](const QString &message) {
    QJsonObject cStatus = {{"focusAdvisorMessage", message}};
    ekosLiveClient.get()->message()->updateFocusStatus(cStatus);
});
```
There are 15+ call sites like this across `manager.cpp` (`updateCaptureStatus`,
`updateFocusStatus`, `updateGuideStatus`, `updateAlignStatus`, `updateMountStatus`,
`updateDomeStatus`, `updateCapStatus`) — this is the exhaustive, already-working list of
"what Ekos state is tracked and JSON-ified." None of this needs to change.

### `Message`/`Media` broadcast to a fixed 2-slot pair, not a dynamic client list

Every send method broadcasts unconditionally (`message.cpp:2498-2545`, all overloads):
```cpp
void Message::sendResponse(const QString &command, const QJsonObject &payload)
{
    for (auto &nodeManager : m_NodeManagers)
        nodeManager->message()->sendResponse(command, payload);
}
```
`m_NodeManagers` is the fixed `{Online, Offline}` pair, not a dynamic per-connected-client
list. `onTextReceived` does identify which `Node` sent an incoming command
(`qobject_cast<Node*>(sender())`, used e.g. for `SET_CLIENT_STATE`), but replies still
broadcast to every configured manager rather than targeting the requester — there is no
per-client addressing anywhere in this code.

**Decision (2026-07-27): this is fine.** Single primary phone, broadcast semantics
acceptable. No need to generalize this into a true multi-session architecture.

### Confirmed: remote profile configuration + indiserver launch already works via `Message`

Traced whether a remote client can configure and launch `indiserver` the same way a
local user does. **Yes, already implemented, comes for free from reusing `Message`
unmodified:**

`Message::processProfileCommands` (`message.cpp:1286`) handles `START_PROFILE`:
```cpp
if (command == commands[START_PROFILE]) {
    if (m_Manager->getEkosStartingStatus() != Ekos::Idle) m_Manager->stop();
    m_Manager->setProfile(payload["name"].toString());
    m_Manager->start();   // same call the local GUI "Start" button makes
}
```
`Ekos::Manager::start()` (`manager.cpp:1102`) branches on `ProfileInfo::isLocal()`
(`profileinfo.h:26`, `return host.isEmpty()`):
- Local profile (no `host`) → `DriverManager::Instance()->startDevices(managedDrivers)`
  — actually spawns `indiserver` + the profile's driver processes on the Pi.
- Remote profile (`host` set) → `DriverManager::Instance()->connectRemoteHost(...)` —
  connects as a client to an indiserver already running elsewhere.

Full profile *configuration* (not just start/stop) is also already wired:
`ADD_PROFILE`/`UPDATE_PROFILE`/`DELETE_PROFILE`/`SET_PROFILE_MAPPING`/
`SET_PROFILE_PORT_SELECTION` all call straight into `Ekos::Manager`'s existing
profile-editing methods (`addNamedProfile`, `editNamedProfile`, etc.) — the same
backing store the GUI's Profile Editor uses.

**No new code needed for this.** A client can create/edit a profile (drivers, mount,
camera, connection config) and `START_PROFILE` to launch `indiserver` on the Pi, exactly
as a local user would via the GUI.

---

## Design plan

**Keep, unmodified:**
- `Ekos::Manager`'s existing signal-wiring in `manager.cpp` (all the `ekosLiveClient.get()->message()->updateXStatus(...)` call sites) — the data-producing side is untouched.
- `message.h`/`.cpp`, `media.h`/`.cpp`, `commands.h` — the JSON protocol itself, including
  `processProfileCommands` — remote profile configuration + `indiserver` launch/stop
  already works through this unmodified (see above).

**Replace:**
- `NodeManager` (HTTP auth + client-dial-out `Node` management) → a new class wrapping
  `QWebSocketServer`, listening on a configured port, accepting incoming connections
  from the mobile app instead of dialing out to a configured URL.
- `EkosLiveClient`'s two-slot (`Online`/`Offline`) `NodeManager` setup → simplified to
  the new listener class, no auth dialog/keychain/JWT machinery. Renamed: namespace
  `EkosLive` → `EkosRemote`, class `EkosLive::Client` → `EkosRemote::Server`,
  `Ekos::Manager`'s `ekosLiveClient` member → `ekosRemote` (same construction slot,
  not a parallel member — see decision #2 below).
- `cloud.h`/`.cpp` → drop entirely, not needed.
- `Node` extended in place (not forked) — pointer-ify `m_WebSocket`, add
  `adoptSocket(QWebSocket*)` for the accept-side path (decision #1 below).

**Keep the broadcast pattern as-is** in `Message`/`Media` — per the scope decision, a
small/fixed connected-client set is fine; this is not a multi-session redesign.

**Decisions (2026-07-27):**
1. **Extend `Node`, don't fork a new class.** `Node` currently owns `m_WebSocket` as a
   value member (`node.h:72`) and only knows how to dial out (`connectServer()` →
   `m_WebSocket.open(url)`, `node.cpp:40`). Change `m_WebSocket` to a pointer, add
   `Node::adoptSocket(QWebSocket*)` that takes an already-connected socket (from
   `QWebSocketServer::nextPendingConnection()`), rewires the same `connected`/
   `disconnected`/`textMessageReceived` signal hookups the ctor does today, and skips
   `open()` for this path. `sendResponse`/`sendEvent`/etc. are untouched — they only
   call methods on `m_WebSocket` regardless of how it got connected.
2. **Same construction slot, renamed.** `Ekos::Manager`'s `ekosLiveClient` member
   (type `EkosLive::Client`) is misleadingly named — it's just where KStars holds the
   `Message`/`Media` pair that ~15+ signal-wiring call sites in `manager.cpp` push
   status into (`ekosLiveClient.get()->message()->updateFocusStatus(...)`, etc). Since
   this fork drops stock EkosLive entirely (no need to run both), repurpose that same
   slot instead of adding a parallel member — zero changes needed at those 15+ call
   sites, since they only touch `.message()`/`.media()` accessors. Rename throughout
   (user, 2026-07-27: "ekosLive -> ekosRemote"), swapping `Live`→`Remote`: namespace
   `EkosLive` → `EkosRemote`, source dir `kstars/ekos/ekoslive/` → `kstars/ekos/ekosremote/`,
   member `ekosLiveClient` → `ekosRemote`, class `EkosLive::Client` → `EkosRemote::Server`
   (`Client`→`Server` per decision above, since this class now listens, it doesn't dial out).
3. **No auth.** Trusted local network; skip the JWT/HTTP-auth handshake entirely for
   the new listener. `NodeManager::authenticate()`'s whole flow (`nodemanager.cpp:147`)
   is dropped, not adapted.
4. **Superseded (user, mid-implementation, 2026-07-27): hardcoded port, not a kcfg
   Options entry.** ~~New Options/kcfg entry for the listen port, analogous to
   `Options::ekosLiveOfflineServer()`~~ — user reconsidered while Phase 0 rename was
   in flight: "it looks better to fix the port number. this server should always be
   enabled when kstars is running." So: fixed port constant in code (no UI/config),
   and the server starts automatically whenever KStars runs — no enable/disable
   toggle, no `AutoStartEkosRemote`-style opt-in checkbox. This also means the
   existing `RememberCredentials`/`AutoStartEkosRemote`/`EkosRemoteUsername`/
   keychain/enrollment-token machinery in `ekosremoteserver.cpp` (all auth/dial-out
   leftovers) gets deleted outright in Phase 2/3, not just renamed.

## Related

- `docs/EkosRemote-Client-Guide.md` — protocol reference for the mobile app side, written
  once the fork above was implemented and build-verified.

- `~/.claude/projects/-home-soo-cc/memory/kstars_websocket_fork.md` — persistent memory
  version of this trace (for future Claude Code sessions on this project).
- `~/.claude/projects/-home-soo-cc/memory/user_ekos_mobile_app.md` — user/project context.
- `docs/BUILD-AND-PACKAGE.md` — the cross-compile pipeline this fork will eventually build
  through (`repo/kstars` git clone, `make kstars-deb`, etc.).
