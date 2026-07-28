# EkosRemote — Mobile Client Developer Guide

Protocol reference for writing a mobile app that controls Ekos (KStars' astrophotography
automation module) over the network, talking to the `EkosRemote` fork of KStars running on
the Raspberry Pi. This documents the wire protocol as implemented in
`repo/kstars/kstars/ekos/ekosremote/`; when in doubt, that source is authoritative — this
guide points at exact files/functions rather than re-deriving behavior that could drift.

**For the exhaustive command-by-command payload reference** (every one of the ~190
commands, exact request/response field shapes, dead/unimplemented commands, known quirks),
see `docs/EkosRemote-Command-Reference.md`. This guide covers the lifecycle/architecture
picture; that doc is the API reference.

## Architecture

- **The Pi listens, the phone connects.** No cloud/relay server, no account system. Connect
  directly to the Pi's IP.
- **Server is always on.** `EkosRemote::Server` starts its listener unconditionally when
  KStars launches — no enable/disable toggle, no auto-start setting to configure.
- **No authentication.** Trusted local network only. Anything that can reach the port can
  control Ekos.
- **Single primary client, broadcast semantics.** The server doesn't track "who sent this
  request" for the purpose of targeting replies — all responses/pushes go to whatever is
  connected. Designed for exactly one phone at a time; a second simultaneous client will see
  everything the first one does.

## Connecting

Two independent WebSocket connections, both to the same port, different paths:

| Channel | Path | Purpose |
|---|---|---|
| Message | `ws://<pi-ip>:9000/message/ekos` | JSON commands, state pushes, RPC |
| Media | `ws://<pi-ip>:9000/media/ekos` | Binary image/frame data |

Port is fixed at `EkosRemote::Server::Port` (`ekosremoteserver.h`) — currently **9000**. No
TLS (`ws://`, not `wss://`). No handshake/auth step — the WebSocket upgrade itself is the
entire connection process. `NodeManager` (`nodemanager.cpp`) accepts the connection and
routes it to the Message or Media node by matching the HTTP request path exactly
(`/message/ekos` or `/media/ekos`); anything else is rejected and the socket closed.

**First thing to send after connecting** (on the Message channel): a `set_client_state`
command with `payload.state = true` (see below). Until you do, most server→client pushes are
suppressed.

## Message channel — envelope format

Every frame on the Message channel is a single JSON text message:

```json
{"type": "<command_string>", "payload": { ... }}
```

- `type` is one of the string values in the `commands` map, `commands.h` — e.g.
  `"get_connection"`, `"capture_start"`, `"new_capture_state"`. The C++ side has a matching
  `enum COMMANDS` (e.g. `GET_CONNECTION`, `CAPTURE_START`, `NEW_CAPTURE_STATE`); the enum name
  and wire string differ (`commands.h` is the exact mapping — always look there, not the
  enum name, for the string to put on the wire).
- `payload` is a `QJsonObject` (occasionally sent as a `QJsonArray`, `QString`, or `bool` for
  simple pushes — same envelope shape either way).
- Commands you send are dispatched in `Message::onTextReceived` (`message.cpp:118`), which
  either matches a specific command or dispatches by string prefix (`"capture_"`, `"mount_"`,
  `"focus_"`, `"guide_"`, `"align_"`, `"polar_"`, `"train_"`, `"scope_"`, `"profile_"`,
  `"dslr_"`, `"option_"`, `"scheduler"`, `"fm_"`, `"dark_library_"`, `"device_"`,
  `"astro_"`, `"file_"`, `"artificial_horizon_"`, `"livestacker_"`) to a per-area handler
  (`processCaptureCommands`, `processMountCommands`, etc., all in `message.cpp`).

**commands.h has ~230 command entries** — this guide covers the lifecycle/RPC/profile
commands you need to get started plus representative examples of the state-push commands.
For anything module-specific (capture sequence editing, mount motion, guiding, alignment,
scheduler jobs, dark library, filter manager, DSLR settings, astronomy lookups, live
stacking, artificial horizon, low-level device property access...), grep `commands.h` for
the area prefix and read the matching `process*Commands` function in `message.cpp` — each
one is a plain `if (command == commands[...])` chain with the exact payload shape inline.

## Client lifecycle

**`set_client_state`** (`SET_CLIENT_STATE`) — send `{"type": "set_client_state", "payload": {"state": true}}`
right after connecting, and `{"state": false}` when backgrounding/disconnecting cleanly.
Handled in `Message::onTextReceived` (`message.cpp:150-190`):
- Gates whether the server sends you responses/events at all — `Node::sendResponse()`
  (`node.cpp`) checks `m_isConnected && m_ClientState`, and `m_ClientState` starts `false`
  until you send this. (`sendEvent()` — used for e.g. `new_notification` — only requires
  `m_isConnected`, not client state, so a few push types arrive even before you announce
  state.)
- Also resumes/pauses KStars' internal clock as a side effect (so the sky-map clock isn't
  ticking pointlessly while nothing is watching).

**`get_connection`** (`GET_CONNECTION`) → server replies `new_connection_state`
(`NEW_CONNECTION_STATE`) with `{"connected": true, "online": <bool Ekos is fully started>}`
(`Message::sendConnection`, `message.cpp:2631`).

**`get_states`** (`GET_STATES`) → server replies with a burst of current-state pushes for
every active module (capture, mount, focus, guide, align + its settings) — the equivalent of
"send me everything so I can draw my UI right now" (`Message::sendStates`, `message.cpp:2645`).
Only works once Ekos itself has finished starting (`m_Manager->getEkosStartingStatus() ==
Ekos::Success`) — sent commands are gated on this same check for most module-area commands
(`message.cpp:268`).

**`get_profiles`** / **`get_drivers`** / **`get_scopes`** / **`get_dslr_lenses`** — send these
early too, to populate initial UI (equipment profiles, INDI driver list, scope/optics list,
DSLR lens list).

## Generic RPC: INVOKE_METHOD / SET_PROPERTY / GET_PROPERTY

For anything not covered by a dedicated command, you can reach into KStars' Qt object graph
directly:

```json
{"type": "get_property", "payload": {"object": "Capture", "name": "targetName"}}
```
→ `{"type": "get_property", "payload": {"result": true, "value": <...>}}`

```json
{"type": "set_property", "payload": {"object": "Capture", "name": "someProperty", "value": <...>}}
```

```json
{"type": "invoke_method", "payload": {"object": "Capture", "name": "someSlot", "args": [{"type": 10, "value": "foo"}]}}
```

The method name key is **`"name"`, not `"method"`** (`Message::invokeMethod`, `message.cpp:3082`, reads
`payload["name"]`). Each entry in `"args"` must be an object `{"type": <int>, "value": <...>}`,
not a bare value — `"type"` is a `QVariant::Type` enum integer (Qt5; this build predates Qt6)
telling `Message::parseArgument` (`message.cpp:2987`) how to unmarshal `"value"`. Supported types:

| `type` | Qt type | Notes |
|---|---|---|
| 1 | `Bool` | |
| 2 | `Int` | |
| 3 | `UInt` | |
| 4 | `LongLong` | unmarshaled into a plain `int` (see source) |
| 5 | `ULongLong` | unmarshaled into a plain `uint` (see source) |
| 6 | `Double` | |
| 10 | `String` | |
| 17 | `Url` | |
| 21 | `Size` | `"value"` is `{"width": <int>, "height": <int>}` |

Anything else falls to `default: break;` and the call silently fails to build that argument.
Example — select a profile (without starting it) via `Ekos::Manager::setProfile(const QString&)`:
```json
{"type": "invoke_method", "payload": {"object": "Manager", "name": "setProfile", "args": [{"type": 10, "value": "My Profile"}]}}
```

`"object"` is resolved by `Message::findObject` (`message.cpp:2952`) via Qt's `objectName()`,
checked in this order: the literal string `"Manager"` (the `Ekos::Manager` singleton itself),
then `findChild<QObject*>()` under `Manager`, then under `INDIListener::Instance()`, then by
scanning open FITS viewer tabs' view `objectName()`, then finally under the top-level
`KStars` instance. In practice: use the Qt object name of the Ekos module/widget you want
(e.g. `"Capture"`, `"Mount"`, `"Focus"`) — check the relevant `.cpp` for `setObjectName()` if
unsure. `SET_PROPERTY`/`INVOKE_METHOD` use Qt's meta-object system (`QMetaObject::invokeMethod`
/ `QObject::setProperty`), so the target must be a `Q_PROPERTY` or `Q_INVOKABLE`/slot exposed
via Qt's meta-object — plain C++ members aren't reachable this way.

## Profile management (fully supported, no local-user-only limitation)

A remote client can create/edit equipment profiles and start/stop `indiserver` on the Pi
exactly as the local GUI does — this goes through the same `Ekos::Manager` methods the
Profile Editor UI calls (`Message::processProfileCommands`, `message.cpp`, dispatches
`profile_*` commands).

Profile JSON shape (from `Ekos::Manager::addNamedProfile`'s docstring, `manager.h`):
```json
{
  "name": "My Profile",
  "auto_connect": true,
  "port_selector": false,
  "mode": "local",
  "remote_host": "localhost",
  "remote_port": "7624",
  "guiding": 0,
  "remote_guiding_host": "localhost",
  "remote_guiding_port": "4400",
  "use_web_manager": false,
  "web_manager_port": 8624,
  "primary_scope": 0,
  "guide_scope": 0,
  "driver_source": "system",
  "drivers": {"Telescopes": ["Telescope Simulator"], "CCDs": ["CCD Simulator"]}
}
```
(`"drivers"` also accepts a flat array of driver labels; a legacy per-role key form
—`mount`/`ccd`/`guider`/`focuser`/etc.— is still accepted but deprecated. `"mode": "remote"`
+ `remote_host`/`remote_port` connects to an indiserver running elsewhere instead of
spawning one locally — see `ProfileInfo::isLocal()`, `profileinfo.h:26`.)

Commands (wire strings from `commands.h`):

| Command string | Effect |
|---|---|
| `profile_add` | Create a new profile (`ADD_PROFILE`) |
| `profile_update` | Edit an existing profile (`UPDATE_PROFILE`) |
| `profile_delete` | Delete a profile (`DELETE_PROFILE`) |
| `profile_get` | Fetch one profile (`GET_PROFILE`) |
| `get_profiles` | List all profiles (`GET_PROFILES`) |
| `profile_start` | `{"name": "My Profile"}` — stops Ekos if running, sets the named profile, calls `Manager::start()`. Local profile → spawns `indiserver` + drivers on the Pi. Remote profile → connects to indiserver elsewhere. (`START_PROFILE`) |
| `profile_stop` | Stops Ekos (`STOP_PROFILE`) |
| `profile_set_mapping` | Port/device mapping for a profile (`SET_PROFILE_MAPPING`) |
| `profile_set_port_selection` / `profile_get_port_selection` | Port selector state |

## Status pushes (server → client)

Every Ekos module's status changes get pushed automatically once connected — this is wired
in `Ekos::Manager` (`manager.cpp`, ~15+ call sites like
`ekosRemote.get()->message()->updateFocusStatus(...)`) and unchanged by this fork. Common
ones:

| Command string | Enum | Sent when |
|---|---|---|
| `new_connection_state` | `NEW_CONNECTION_STATE` | On `get_connection`, and on Ekos/INDI status change |
| `new_capture_state` | `NEW_CAPTURE_STATE` | Capture module status change |
| `new_mount_state` | `NEW_MOUNT_STATE` | Mount status change |
| `new_focus_state` | `NEW_FOCUS_STATE` | Focus module status change |
| `new_guide_state` | `NEW_GUIDE_STATE` | Guide module status change |
| `new_align_state` | `NEW_ALIGN_STATE` | Align module status change |
| `new_polar_state` | `NEW_POLAR_STATE` | Polar alignment assistant stage change |
| `new_dome_state` / `new_cap_state` | — | Dome/dust-cap status change |
| `new_scheduler_state` | `NEW_SCHEDULER_STATE` | Scheduler status change |
| `new_temperature` | `NEW_TEMPERATURE` | Camera/focuser temperature update |
| `new_notification` | `NEW_NOTIFICATION` | General KStars notification/dialog message |
| `new_livestacker_state` | `NEW_LIVESTACKER_STATE` | Native live-stacking progress/completion |
| `new_mosaic_tiles` | `NEW_MOSAIC_TILES` | Mosaic planner tile update |

Payload shapes are small, ad-hoc `QJsonObject`s built right where each is sent — e.g. mount
status includes `status`/`target`/`slewRate`/`pierSide` (`Message::sendStates`,
`message.cpp:2657`). Read the specific `send*`/`update*` function in `message.cpp` for the
exact fields of any push you need.

## Media channel — binary frame format

Every binary WebSocket frame on the Media channel (`/media/ekos`) has the same fixed layout,
built in `Media::upload()` (`media.cpp:391` and `:472`):

```
[ 512-byte JSON metadata header, null-padded ][ JPEG image bytes ]
```

- Header length is fixed at `Media::METADATA_PACKET = 512` bytes (`media.h:124`) — always
  read exactly the first 512 bytes, `QJsonDocument::fromJson` on that slice after trimming
  trailing null bytes, then treat everything after byte 512 as JPEG data.
- Header fields (from `media.cpp:420`): `resolution`, `size`, `channels`, `mean`, `median`,
  `stddev`, `min`, `max`, `bin`, `bpp`, `uuid`, `exposure`, `focal_length`, `aperture`,
  `gain`, `pixel_size`, `shadows`, `midtones`, `highlights`, `hasWCS`, `hfr`, `view`, `ext`
  (always `"jpg"` currently).
- `uuid` is really a **frame-type tag**, not a unique ID — conventions in use:
  `""` (empty) = regular capture preview frame; `"+A"` = align frame; `"+F"` = focus frame;
  `"+G"` = guide frame; `"+D"` = dark-library frame. Any tag starting with `+` is treated as
  a "fast" frame and gets scaled to half width (`Media::HB_IMAGE_WIDTH = 1920`, halved for
  `+`-tagged frames) with faster (lower-quality) scaling; JPEG quality is fixed at
  `Media::HB_IMAGE_QUALITY = 90`.
- Media channel also carries a handful of JSON text commands (same envelope as the Message
  channel) for things like `align_load_and_slew` where a client uploads image data — see
  `Media::onTextReceived`/`onBinaryReceived` in `media.cpp` for the incoming direction.

## Practical notes

- **No reconnect/backoff logic needed server-side** — the server just accepts whatever
  connects to the two paths. Your app owns reconnect behavior.
- **`Node::sendResponse` vs `sendEvent`**: responses require `SET_CLIENT_STATE(true)` to have
  been sent; events (a small set, e.g. notifications) go out regardless. If you connect and
  see nothing back from a request you sent, check you sent `set_client_state` first.
- Since there's no per-client targeting (single primary client, broadcast design — see
  Architecture above), don't build assumptions about request/response correlation beyond
  "the last thing I asked for is probably what just arrived" — fine for one client, would
  need real work to support multiple simultaneous clients cleanly.
