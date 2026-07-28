# EkosRemote — Full Command & Payload Reference

Exhaustive, code-grounded reference for every wire command in the EkosRemote fork. This is
the companion to `docs/EkosRemote-Client-Guide.md` — read that first for the envelope
format, connection lifecycle, and architecture overview. This doc exists because the guide
intentionally didn't enumerate all ~190 commands' exact payload shapes; this does.

**Source of truth for everything below:** `repo/kstars/kstars/ekos/ekosremote/message.cpp`
(Message channel, `ws://<pi-ip>:9000/message/ekos`) and `media.cpp` (Media channel,
`ws://<pi-ip>:9000/media/ekos`), both cited by line number. Where a command forwards into a
plain Ekos module (`Capture`, `Focus`, `Mount`, etc.) not itself part of this fork, that's
noted rather than re-derived.

**Conventions:**
- **Request payload** tables: `Field | Type | Required/Optional (default) | Notes`. "none" =
  the handler reads no payload fields at all (safe to send `{}`).
- **Response**: either the reply command + payload shape, or "none (fire-and-forget)" —
  meaning the only way to observe the effect is via a status push, not a direct reply.
- Every command not marked "server push only" is client-invocable — send it and (if it has
  a response) expect one back.

---

## 1. Connection lifecycle & envelope mechanics

Every outbound message (any `sendResponse`/`sendEvent` overload) is built by `Node`
(`node.cpp`) as `{"type": <command>, "payload": <payload>}`, compact JSON. `Message`'s
send helpers are thin fan-out wrappers that loop over every configured `NodeManager` — no
per-client targeting exists anywhere in this layer (consistent with the single-primary-
client design).

**Gating** (`node.cpp:168-244`):
- `sendResponse` (all overloads) and `sendTextMessage`/`sendBinaryMessage` require **both**
  `m_isConnected` (socket open) **and** `m_ClientState` (you sent
  `set_client_state {"state": true}`). If either is false, the message is silently dropped
  — no queueing, no error.
- `sendEvent` only requires `m_isConnected` — goes out even before `set_client_state`. This
  is why `new_notification` can arrive before you've announced client state, while every
  ordinary command reply cannot.
- **This means:** a client that connects but never sends `set_client_state {"state": true}`
  receives `new_notification` events and nothing else. Every `sendResponse`-based reply —
  the vast majority of commands in this doc — is silently swallowed until then.

**The Media channel does not use `set_client_state` at all** — connecting is sufficient to
start receiving frames. See §14.

### `get_connection` (`GET_CONNECTION`) — message.cpp:139

**Request:** none
**Response:** `new_connection_state` via `sendConnection()` (message.cpp:2631):
| Field | Type | Notes |
|---|---|---|
| `connected` | bool | always `true` |
| `online` | bool | `m_Manager->getEkosStartingStatus() == Ekos::Success` |

### `set_client_state` (`SET_CLIENT_STATE`) — message.cpp:150

**Request:**
| Field | Type | Required/Optional (default) | Notes |
|---|---|---|---|
| `state` | bool | Optional (`false`) | |

**Response:** none directly. Side effects: gates all replies as above; `true` starts
KStars' internal clock if idle; `false` stops it if Ekos is idle too (power save).

### `logout` (`LOGOUT`) / `session_expired` (`SESSION_EXPIRED`) — message.cpp:143

**Request:** none read. **Response:** none — emits internal `globalLogoutTriggered(url)`
signal, not a wire reply. Handler returns immediately, skipping any burst fallthrough.

### `get_states` (`GET_STATES`) — message.cpp:271

Gated: only runs if Ekos is `Success` (this gate applies to every command from here through
`get_devices` below too).

**Request:** none. **Response:** a **burst** of separate pushes from `sendStates()`
(message.cpp:2645-2707), each sent only if the module exists:

| Condition | Push | Payload |
|---|---|---|
| capture module | `new_capture_state` | `{"status": <untranslated status string>}` |
| (same) | `capture_get_sequences` | `captureModule()->getSequence()` (array) |
| mount module | `new_mount_state` | `{"status", "target" (label text), "slewRate" (int), "pierSide" (int)}` |
| focus module | `new_focus_state` | `{"status": <string>}` |
| guide module | `new_guide_state` | `{"status": <string>}` |
| align module | `new_align_state` | `{"status": <string>}` |
| (same) | `align_get_all_settings`-shape | `alignModule()->getAllSettings()` |
| PAH assistant exists | `new_polar_state` | `{"stage", "enabled" (bool), "message" (HTML stripped to plain text)}` |

### `get_stellarsolver_profiles` (`GET_STELLARSOLVER_PROFILES`) — message.cpp:273

Same Ekos-Success gate. **Request:** none. **Response:**
| Field | Type | Notes |
|---|---|---|
| `focus` | array of strings | only present if a focus module exists |
| `align` | array of strings | only present if an align module exists |

(No `guide` field — commented out as `// TODO` in source, even though a guide module may exist.)

### `get_devices` (`GET_DEVICES`) — message.cpp:275

Same gate. **Response:** array from `INDIListener::devices()`, one object each:
`{"name", "connected" (bool), "version", "interface" (int, INDI interface bitmask)}`.

---

## 2. Generic RPC — `invoke_method` / `set_property` / `get_property`

For anything not covered by a dedicated command — reach into KStars' Qt object graph
directly.

### `"object"` resolution — `Message::findObject`, message.cpp:2952-2981

In order:
1. Literal string `"Manager"` → the `Ekos::Manager` singleton itself, directly.
2. `m_Manager->findChild<QObject*>(name)` — any child of Ekos Manager with matching `objectName()`.
3. `INDIListener::Instance()->findChild<QObject*>(name)`.
4. Every open FITS viewer's tabs: `tab->getView()->objectName() == name`.
5. `KStars::Instance()->findChild<QObject*>(name)` — does **not** include independent
   top-level objects whose parent is null (e.g. a standalone `FITSViewer`).
6. No match → `nullptr`, command silently no-ops.

### `get_property` (`GET_PROPERTY`) — message.cpp:220

**Request:** `{"object": string, "name": string}` (property name, passed to `QObject::property`).

**Response:** same command string:
| Field | Type | Notes |
|---|---|---|
| `result` | bool | `true` only if object found AND property returned a valid `QVariant` |
| `value` | any | present only if `result: true` |

### `set_property` (`SET_PROPERTY`) — message.cpp:214

**Request:** `{"object": string, "name": string, "value": any}` — `value` is
`payload["value"].toVariant()`, no explicit type tag needed (unlike `invoke_method`).
Target must be a `Q_PROPERTY` with a setter.

**Response:** none (fire-and-forget). No error if object/property doesn't exist or isn't writable.

### `invoke_method` (`INVOKE_METHOD`) — message.cpp:208, `Message::invokeMethod` message.cpp:3082

**Request:**
| Field | Type | Required/Optional | Notes |
|---|---|---|---|
| `object` | string | Required | see resolution above |
| `name` | string | Required | method/slot name — **the key is `"name"`, not `"method"`** |
| `args` | array of `{"type": int, "value": any}` | Optional | see type table below |

Each `args[]` element's `type` is a `QVariant::Type` enum integer (this build predates Qt6):

| `type` | Qt type | Notes |
|---|---|---|
| 1 | Bool | |
| 2 | Int | |
| 3 | UInt | |
| 4 | LongLong | **narrowed** — stored/passed as plain C++ `int`, not `qlonglong` |
| 5 | ULongLong | **narrowed** — passed as `uint`, not `qulonglong` |
| 6 | Double | |
| 10 | String | |
| 17 | Url | |
| 21 | Size | `value` must be `{"width": int, "height": int}` |
| anything else | — | that arg is **dropped entirely** (not passed as null — the slot disappears, shifting subsequent positions) |

Dispatch is by **argument count only** (max 4):
- `"args"` key **absent** entirely → zero-arg `QMetaObject::invokeMethod(context, name)`.
- `"args"` **present but empty after parse failures** → **nothing is invoked** (no `case 0`
  in the dispatch switch) — different behavior than omitting `"args"`.
- 1–4 successfully-parsed args → invoked with that many.
- 5+ → silently dropped, not invoked.

**Response:** none (fire-and-forget) — no ack either way. Observe effects via later status
pushes or a follow-up `get_property`.

**Example — select a profile without starting it** (no dedicated command exists for this):
```json
{"type": "invoke_method", "payload": {"object": "Manager", "name": "setProfile", "args": [{"type": 10, "value": "My Profile"}]}}
```

---

## 3. Profiles

### `get_profiles` (`GET_PROFILES`) — message.cpp:202 (top-level, not in `processProfileCommands`)

**Request:** none. **Response** (`sendProfiles`, message.cpp:1340):
```json
{"selectedProfile": "<name>", "profiles": [ <profile>, ... ]}
```
Each `<profile>` is `ProfileInfo::toJson()` — **verified real schema** (`profileinfo.cpp:135`):

| Field | Type | Notes |
|---|---|---|
| `name` | string | |
| `auto_connect` | bool | |
| `port_selector` | bool | |
| `mode` | string | `"local"` if host empty, else `"remote"` |
| `remote_host` | string | |
| `remote_port` | int | |
| `guiding` | int | guider-type enum |
| `remote_guiding_host` | string | |
| `remote_guiding_port` | int | |
| `use_web_manager` | bool | `true` iff `INDIWebManagerPort != -1` — **no port number field is exposed** |
| `mount`, `ccd`, `guider`, `focuser`, `filter`, `ao`, `dome`, `weather`, `aux1`-`aux4` | string | per-role driver label (legacy convenience) |
| `remote` | string | free-text remote drivers |
| `driver_source` | string | |
| `drivers` | object `{"<DeviceFamily>": [labels...]}` | full structured driver map |
| `scripts` | string | only present if non-empty |

> ⚠️ **`web_manager_port`, `primary_scope`, `guide_scope` do NOT exist** — an earlier
> hand-written doc listed these; they were never real fields. Sending them in
> `profile_add`/`profile_update` is silently ignored.

### `profile_start` (`START_PROFILE`) — message.cpp:1288

**Request:** `{"name": string}` (required). Stops Ekos if running, `setProfile(name)`, syncs
KStars clock to UTC-now, then `Manager::start()` — **local** profile spawns `indiserver` +
drivers on the Pi; **remote** connects to an indiserver elsewhere.

**Response:** none directly — watch `new_connection_state` (`online` flips true) and the
module status-push stream.

### `profile_stop` (`STOP_PROFILE`) — message.cpp:1298

**Request:** none. Stops Ekos, closes all FITS viewers, clears property subscriptions.
**Response:** none directly — watch `new_connection_state` (`online: false`).

### `profile_add` (`ADD_PROFILE`) / `profile_update` (`UPDATE_PROFILE`) — message.cpp:1307, 1312

Both consumed by `ProfileEditor::setSettings` (`profileeditor.cpp:505-595`) — this is the
**real** schema (verified against reserved-key list in code):

| Field | Type | Required/Optional (default) | Notes |
|---|---|---|---|
| `name` | string | Required | For `profile_update`, also selects which existing profile to load first |
| `auto_connect` | bool | Optional (true) | |
| `port_selector` | bool | Optional (false) | |
| `mode` | string | Optional | `"local"` or `"remote"`; anything else → both unchecked |
| `remote_host` | string | Optional ("localhost") | only meaningful if `mode: "remote"` |
| `remote_port` | string | Optional ("7624") | |
| `guiding` | int | Optional (0) | index into guide-type combo |
| `remote_guiding_host` | string | Optional ("localhost") | |
| `remote_guiding_port` | string | Optional ("4400") | |
| `use_web_manager` | bool | Optional (false) | |
| `remote` | string | Optional (keeps existing) | free-text remote drivers field |
| `driver_source` | string | Optional ("system") | |
| `scripts` | string | Optional | preserved verbatim |
| `drivers` | array of strings, OR object `{"<DeviceFamily>": ["label", ...]}` | Optional | **preferred**; family keys match `ProfileInfo.drivers`' keys (`"Telescopes"`, `"CCDs"`, `"Focusers"`, `"Filter Wheels"`, etc.) |
| *(legacy)* flat per-role keys (`mount`, `ccd`, `guider`, `focuser`, ...) | string | Optional | only consulted if `"drivers"` key absent; any unrecognized key is treated this way |

**Response:** `get_profiles` (full refreshed list), sent automatically.

### `profile_get` (`GET_PROFILE`) — message.cpp:1317

**Request:** `{"name": string}`. **Response: none** — `m_Manager->getNamedProfile(name)` is
called but its return value is never sent anywhere. **Dead on the response side** — use
`get_profiles` and filter client-side instead.

### `profile_delete` (`DELETE_PROFILE`) — message.cpp:1321

**Request:** `{"name": string}`. **Response:** `get_profiles` (refreshed list) — but
`Manager::deleteNamedProfile` silently refuses to delete `"Simulators"` or the currently
active profile; no error is sent, the list just comes back unchanged.

### `profile_set_mapping` (`SET_PROFILE_MAPPING`) — message.cpp:1326

**Request:** whole payload forwarded to `Manager::setProfileMapping(payload)` (shape defined
in `manager.cpp`, not further traced here). **Response:** none observed.

### `profile_set_port_selection` (`SET_PROFILE_PORT_SELECTION`) — message.cpp:1330

**Request:** none. Sends `profile_get_port_selection` with payload `false` (hides the
port-selector UI), then `acceptPortSelection()`.

### `profile_get_port_selection` (`GET_PROFILE_PORT_SELECTION`) — **server push only**

Not client-invocable. Bare boolean payload (`true`=show port selector, `false`=hide),
pushed whenever port-selector state changes internally.

---

## 4. Optical Trains & Scopes

### `train_get_all` (`TRAIN_GET_ALL`) — message.cpp:236 (top-level)

**Request:** none. **Response** (`sendTrains`, message.cpp:372): bare JSON array from
`OpticalTrainManager::getOpticalTrains()`. Verified real per-train fields (live test output):
`id`, `name`, `profile`, `mount`, `camera`, `guider`, `focuser`, `filterwheel`, `rotator`,
`reducer`, `dustcap`, `lightbox`, `scope`, `adaptiveoptics`.

### `train_get_profiles` (`TRAIN_GET_PROFILES`) — message.cpp:1526

**Request:** none. **Response** (`sendTrainProfiles`, message.cpp:385): payload is
`ProfileSettings::getSettings()` — per-module optical-train-ID mapping.

### `train_set` (`TRAIN_SET`) — message.cpp:1528

**Request:**
| Field | Type | Required | Notes |
|---|---|---|---|
| `module` | string | Required | one of `"capture"`, `"focus"`, `"guide"`, `"align"`, `"mount"`, `"darklibrary"` — anything else silently ignored |
| `name` | string | Required | optical train name to assign |

**Response:** none directly.

### `train_add` (`TRAIN_ADD`) / `train_update` (`TRAIN_UPDATE`) — message.cpp:1563, 1567

**Request:** whole payload passed to `OpticalTrainManager::addOpticalTrain`/`setOpticalTrain`
(shape defined in `opticaltrainmanager.cpp`, not this file). **Response:** none directly, but
`OpticalTrainManager::updated` is wired (`manager.cpp:3624`) to auto-push `train_get_all`.

### `train_delete` (`TRAIN_DELETE`) — message.cpp:1571

**Request:** `{"name": string}`. **Response:** automatic `train_get_all` push.

### `train_reset` (`TRAIN_RESET`) — message.cpp:1575

**Request:** none (resets current train to defaults). **Response:** automatic `train_get_all` push.

### `train_configuration_requested` (`TRAIN_CONFIGURATION_REQUESTED`) — **server push only**

Bare boolean — `true` when the train-config dialog needs attention (e.g. missing trains).

### `train_accept` (`TRAIN_ACCEPT`) — message.cpp:1579

**Request:** none. Sends `train_configuration_requested: false`, then
`OpticalTrainManager::accept()`.

### `train_settings_get` (`TRAIN_SETTINGS_GET`) — message.cpp:238 (top-level)

**Request:** `{"id": int}` — must be `> 0`, else silent no-op (no response at all).
**Response:** payload is `OpticalTrainSettings::getSettings()`, only sent if non-empty.

### `get_scopes` (`GET_SCOPES`) — message.cpp:204 (top-level)

**Request:** none. **Response** (`sendScopes`, message.cpp:406): bare array, each
`OAL::Scope::toJson()`: `{"id", "model", "vendor", "type", "name", "focal_length", "aperture"}`.

### `scope_add` (`ADD_SCOPE`) — message.cpp:1469

**Request:** `{"model", "vendor", "type"}` (strings, required) + `{"aperture", "focal_length"}` (doubles, required).
**Response:** `get_scopes` (full list), auto-sent after every `scope_*` command.

### `scope_update` (`UPDATE_SCOPE`) — message.cpp:1474

**Request:** same as `scope_add` plus `{"id": string}` (required). **Response:** `get_scopes`.

### `scope_delete` (`DELETE_SCOPE`) — message.cpp:1479

**Request:** `{"id": string}`. **Response:** `get_scopes`.

---

## 5. Capture

### `capture_preview` (`CAPTURE_PREVIEW`) — message.cpp:467
**Request:** none. **Response:** none — `capturePreview()`; watch image/frame push channel.

### `capture_toggle_video` (`CAPTURE_TOGGLE_VIDEO`) — message.cpp:471
**Request:** `{"maxBufferSize": int (512)}`, `{"maxPreviewFPS": int (10)}`, `{"enabled": bool (false)}` — all optional with shown defaults.
**Response:** none.

### `capture_start` / `capture_stop` / `capture_loop` — message.cpp:476, 478, 480
**Request:** none each. **Response:** none — status via `new_capture_state` push.
`capture_loop` calls `startFraming()`.

### `capture_get_sequences` (`CAPTURE_GET_SEQUENCES`) — message.cpp:484
**Request:** none. **Response:** JSON array (`sendCaptureSequence`, message.cpp:561) —
`capture->getSequence()`, shape defined by the Capture module's sequence-queue serializer.

### `capture_add_sequence` (`CAPTURE_ADD_SEQUENCE`) — message.cpp:488
**Request:** none — `createJob()` using current UI-configured settings. **Response:** none;
new job appears in the next `capture_get_sequences`.

### `capture_remove_sequence` (`CAPTURE_REMOVE_SEQUENCE`) — message.cpp:493
**Request:** `{"index": int (0)}`. **Response:** `capture_get_sequences`, but **only sent if
removal failed** — success gives no reply, refresh yourself.

### `capture_clear_sequences` (`CAPTURE_CLEAR_SEQUENCES`) — message.cpp:498
**Request:** none. **Response:** none.

### `capture_save_sequence_file` (`CAPTURE_SAVE_SEQUENCE_FILE`) — message.cpp:502
**Request:** `{"filepath": string}` (required). **Response:** same command, payload = raw
file contents as a string — only sent if save+reread succeeded.

### `capture_load_sequence_file` (`CAPTURE_LOAD_SEQUENCE_FILE`) — message.cpp:514
**Request:** `{"filedata": string}` (optional — if present, written to a temp file and
loaded from there) or `{"filepath": string}` (used only if `filedata` absent).
**Response:** `{"result": bool, "path": string}` — not sent at all if both fields are empty.

### `capture_get_all_settings` / `capture_set_all_settings` — message.cpp:542, 546
Not a fixed schema — `Camera::getAllSettings()`/`setAllSettings()` reflect over every
`QLineEdit`/`QComboBox`/`QDoubleSpinBox`/`QSpinBox`/`QCheckBox`/checkable-`QGroupBox`/
`QRadioButton`/`QSplitter` child widget, keyed by `objectName()`. Get is **debounced** —
queued into `m_DebouncedMap`, flushed ~500ms later by a shared timer that also fires
`Options::self()->save()` (disk write) — batched together with any other pending
`*_get_all_settings` replies from the same window. **Expect the reply asynchronously, not
synchronously.**

Live-captured full field list (this session, real Pi, `Simulators` profile):
`FilterPosCombo`, `altBox`, `azBox`, `cameraTemperatureN`, `cameraTemperatureS`,
`captureBinHN`, `captureBinVN`, `captureCalibrationADUTolerance`, `captureCalibrationADUValue`,
`captureCalibrationDurationManual`, `captureCalibrationParkDome`, `captureCalibrationParkMount`,
`captureCalibrationSkyFlats`, `captureCalibrationUseADU`, `captureCalibrationWall`,
`captureCountN`, `captureDelayN`, `captureEncodingS`, `captureExposureN`, `captureFormatS`,
`captureFrameHN`, `captureFrameWN`, `captureFrameXN`, `captureFrameYN`, `captureGainN`,
`captureISOS`, `captureOffsetN`, `captureTypeS`, `darkB`, `enableDitherPerJob`,
`enforceAutofocusHFR`, `enforceAutofocusOnTemperature`, `enforceGuideDeviation`,
`enforceRefocusEveryN`, `enforceStartGuiderDrift`, `fileDirectoryT`, `fileRemoteDirT`,
`fileUploadModeS`, `formatSuffixN`, `guideDeviation`, `guideDeviationReps`,
`guideDitherPerJobFrequency`, `hFRCheckAlgorithm`, `hFRDeviation`, `hFRThresholdPercentage`,
`inSequenceCheckFrames`, `maxFocusTemperatureDelta`, `opticalTrainCombo`,
`placeholderFormatT`, `postCaptureScript`, `postJobScript`, `preCaptureScript`,
`preJobScript`, `refocusAfterMeridianFlip`, `refocusEveryN`, `startGuideDeviation`,
`targetNameT`, `videoDurationSB`, `videoDurationUnitCB`.

`capture_set_all_settings` also writes through to global `Options` via `KSUtils::setGlobalSettings`.

### `capture_get_preview_label` (`CAPTURE_GET_PREVIEW_LABEL`) — **server push only**

No request handler exists for this in `processCaptureCommands`. `sendPreviewLabel`
(message.cpp:566, `{"preview": string}`) is wired via Qt signal from `manager.cpp:3642` —
fired internally whenever the capture preview label changes, not client-invocable.

### `capture_generate_dark_flats` (`CAPTURE_GENERATE_DARK_FLATS`) — message.cpp:552
**Request:** none. **Response:** none — `generateDarkFlats()`.

### `capture_toggle_camera` / `capture_toggle_filter_wheel` (`CAPTURE_TOGGLE_CAMERA`/`CAPTURE_TOGGLE_FILTER_WHEEL`)

Present in `commands.h`; not separately detailed by extraction — same toggle pattern as
`capture_toggle_video`, check `processCaptureCommands` directly for exact fields if needed.

---

## 6. Mount

Guard: the entire handler returns early (with a warning log) if no mount module exists —
applies to every command below.

### `mount_abort` / `mount_park` / `mount_unpark` — message.cpp:768, 770, 772
**Request:** none each. **Response:** none directly — watch `new_mount_state`.

### `mount_set_tracking` (`MOUNT_SET_TRACKING`) — message.cpp:773
**Request:** `{"enabled": bool (false)}`. **Response:** none.

### `mount_sync_rade` (`MOUNT_SYNC_RADE`) — message.cpp:775
**Request:**
| Field | Type | Default | Notes |
|---|---|---|---|
| `isJ2000` | bool | false | |
| `ra` | string | — | parsed via `dms::fromString(ra, false)` — hours format, e.g. `"12:34:56"` |
| `de` | string | — | parsed via `dms::fromString(de, true)` — degrees format |

Syncs mount's internal position to these coordinates (does **not** slew).
**Response:** none.

### `mount_sync_target` (`MOUNT_SYNC_TARGET`) — message.cpp:782
**Request:** `{"target": string}` — object name, resolved via
`KStarsData::skyComposite()->findByName(target, false)` (fuzzy). Found → syncs position to
it. Not found → silent no-op, no error. **Response:** none.

### `mount_goto_rade` (`MOUNT_GOTO_RADE`) — message.cpp:786
Same payload shape as `mount_sync_rade` — but this one **actually slews**
(`mount->slew(ra.Hours(), de.Degrees())`). **Response:** none directly — watch
`new_mount_state`'s `status`/`target`.

### `mount_goto_target` (`MOUNT_GOTO_TARGET`) — message.cpp:793
**Request:** `{"target": string}` — resolved the same way as `mount_sync_target`, then
`slew(object->ra().Hours(), object->dec().Degrees())`. Not found → silent no-op.
**Response:** none.

### `mount_goto_pixel` (`MOUNT_GOTO_PIXEL`) — message.cpp:826
"Tap on the preview image to slew there":
| Field | Type | Notes |
|---|---|---|
| `camera` | string | must exactly match a connected camera's INDI device name |
| `x` | double | **fraction** in `[0.0, 1.0]` of that camera's most recent image width — not a pixel count, not screen coordinates |
| `y` | double | fraction of image height |

Requires the last image to have WCS solved — if not plate-solved, silently no-ops.
Converts pixel→WCS→JNow, then slews (direct `SkyPoint` overload, no name lookup).
**Response:** none.

### `mount_set_slew_rate` (`MOUNT_SET_SLEW_RATE`) — message.cpp:797
**Request:** `{"rate": int (-1)}` — only applied if `>= 0`; index into driver's slew-rate list.
**Response:** none.

### `mount_set_motion` (`MOUNT_SET_MOTION`) — message.cpp:811
**Request:**
| Field | Type | Notes |
|---|---|---|
| `direction` | string | one of `"N"`/`"S"`/`"E"`/`"W"` — anything else silently ignored |
| `action` | bool | `true`=start, `false`=stop. **Field name is `action`, not `start`/`enabled`.** |

Only one axis moves per call — diagonal motion needs two separate calls, independently stopped.
**Response:** none.

### `mount_toggle_autopark` (`MOUNT_TOGGLE_AUTOPARK`) — message.cpp:861
**Request:** `{"toggled": bool (false)}`. **Response:** none.

### `mount_get_all_settings` / `mount_set_all_settings` — message.cpp:809, 803

Not fixed-field — `Mount::getAllSettings()`/`setAllSettings()` reflect over every
`QComboBox`/`QDoubleSpinBox`/`QSpinBox`/`QCheckBox`/`QTimeEdit` descendant of the Mount
widget tree. Field set from `mount.ui` + sub-forms: `autoParkTime`,
`enableAltitudeLimits`, `enableAltitudeLimitsTrackingOnly`, `enableHaLimit`,
`executeMeridianFlip`, `locationSource`, `maximumAltLimit`, `maximumHaLimit`,
`meridianFlipOffsetDegrees`, `minimumAltLimit`, `opticalTrainCombo`, `parkEveryDay`,
`timeSource`, `useGeographicUpdate`, `useTimeUpdate`, `leftRightCheckObject`,
`upDownCheckObject`.

**Get is debounced** (same 500ms shared-timer mechanism as Capture, batched with any other
pending `*_get_all_settings` — see §5). **Set** writes through to global `Options` too
(persisted to disk) — no ack; follow with a get to confirm.

### `mount_clear` (`MOUNT_CLEAR`) — ⚠️ **NOT IMPLEMENTED**

Declared in `commands.h`, no handler anywhere. Sending it does nothing.

---

## 7. Dome & Dust Cap — ⚠️ **ENTIRELY UNIMPLEMENTED**

`dome_park`, `dome_unpark`, `dome_goto`, `dome_stop`, `cap_park`, `cap_unpark`,
`cap_set_light` are all declared in `commands.h` with wire strings, but **none has a
handler anywhere in `message.cpp` or `media.cpp`**. Sending any of these currently does
nothing — confirmed by exhaustive grep, not missed by an incomplete read.

Status *monitoring* still works fine — `new_dome_state`/`new_cap_state` pushes exist
(`updateDomeStatus`/`updateCapStatus`, message.cpp:2607/2615, wired from `manager.cpp`) —
so a client can display dome/cap state, just can't control them via this fork yet. If you
need dome/cap control, that's new code to add, not something already there and undocumented.

---

## 8. Focus

### `focus_start` / `focus_stop` / `focus_reset` / `focus_loop` — message.cpp:720, 727, 729, 735
**Request:** none each. **Response:** none. `focus_loop` = `startFraming()`.

### `focus_capture` (`FOCUS_CAPTURE`) — message.cpp:722
**Request:** none — `resetFrame()` then `capture()`. **Response:** none.

### `focus_in` / `focus_out` (`FOCUS_IN`/`FOCUS_OUT`) — message.cpp:731, 733
**Request:** `{"steps": int (0)}` each. **Response:** none.

### `focus_set_crosshair` (`FOCUS_SET_CROSSHAIR`) — message.cpp:746
**Request:** `{"x": double (0), "y": double (0)}` — **fractional** (0–1) position within the
focus frame, not pixel coordinates. Calls `selectFocusStarFraction(x, y)`. **Response:** none.

### `focus_get_all_settings` / `focus_set_all_settings` — message.cpp:744, 737

Same reflection pattern as Capture/Mount. Live-captured full field list:
`absTicksSpin`, `defaultFocusTemperatureSource`, `focusAFOptimize`, `focusAFOverscan`,
`focusAdaptStart`, `focusAdaptive`, `focusAdaptiveMaxMove`, `focusAdaptiveMinMove`,
`focusAdvCoarseAdj`, `focusAdvFindStars`, `focusAdvFineAdj`, `focusAdvHelpOnlyChanges`,
`focusAdvUpdateParams`, `focusAlgorithm`, `focusAutoStarEnabled`, `focusBacklash`,
`focusBinning`, `focusBoxSize`, `focusCFZAlgorithm`, `focusCFZAperture`,
`focusCFZDisplayVCurve`, `focusCFZFNumber`, `focusCFZSeeing`, `focusCFZStepSize`,
`focusCFZTau`, `focusCFZTolerance`, `focusCFZWavelength`, `focusCaptureTimeout`,
`focusCurveFit`, `focusDenoise`, `focusDetection`, `focusDonut`, `focusExposure`,
`focusFilter`, `focusFramesCount`, `focusFullFieldInnerRadius`, `focusFullFieldOuterRadius`,
`focusGain`, `focusGaussianKernelSize`, `focusGaussianSigma`, `focusGuideSettleTime`,
`focusHFRFramesCount`, `focusISO`, `focusMaxSingleStep`, `focusMaxTravel`,
`focusMosaicMaskRB`, `focusMosaicSpace`, `focusMosaicTileWidth`, `focusMotionTimeout`,
`focusMultiRowAverage`, `focusNoMaskRB`, `focusNumSteps`, `focusOutSteps`,
`focusOutlierRejection`, `focusOverscanDelay`, `focusR2Limit`, `focusRefineCurveFit`,
`focusRingMaskRB`, `focusSEPProfile`, `focusScanAlwaysOn`, `focusScanDatapoints`,
`focusScanStartPos`, `focusScanStepSizeFactor`, `focusSettleTime`, `focusSplitter`
(base64 `QSplitter::saveState()`), `focusStarMeasure`, `focusStarPSF`, `focusSubFrame`,
`focusSuspendGuiding`, `focusThreshold`, `focusTicks`, `focusTimeDilation`,
`focusTolerance`, `focusUnits`, `focusUseFullField`, `focusUseWeights`, `focusWalk`,
`forceInSeqAF`, `maxFocusFrameFiles`, `opticalTrainCombo`, `rightLayout` (base64 splitter
state), `speedupCtrl`, `speedupShift`, `useFocusDarkFrame`.

`opticalTrainCombo` is stripped internally before applying on `set`. Get is debounced
same as Capture/Mount.

---

## 9. Guide

### `guide_start` / `guide_capture` / `guide_loop` / `guide_stop` / `guide_clear` — message.cpp:670-680
**Request:** none each. **Response:** none. Map to `guide()`, `capture()`, `loop()`,
`abort()`, `clearCalibration()` respectively.

### `guide_get_all_settings` / `guide_set_all_settings` — message.cpp:688, 682

Same reflection pattern. Field list (derived from `guide.ui` widget names — **not
live-verified this session**, unlike Capture/Focus above): `dECGuideEnabled`,
`dECorrDisplayedOnGuideGraph`, `dEDisplayedOnGuideGraph`, `eastRAGuideEnabled`,
`guideAutoStar`, `guideBinning`, `guideDarkFrame`, `guideDelay`, `guideGain`,
`guiderAccuracyThreshold`, `guideSquareSize`, `guideStreamingEnabled`, `guideSubframe`,
`latestCheck`, `opticalTrainCombo`, `rACorrDisplayedOnGuideGraph`,
`rADisplayedOnGuideGraph`, `rAGuideEnabled`, `rMSDisplayedOnGuideGraph`,
`sNRDisplayedOnGuideGraph`, `southDECGuideEnabled`, `westRAGuideEnabled`. Get is debounced.

### `guide_set_calibration_settings` (`GUIDE_SET_CALIBRATION_SETTINGS`) — message.cpp:690

**Request:**
| Field | Type | Default | Effect |
|---|---|---|---|
| `pulse` | int | 0 | `Options::setCalibrationPulseDuration` |
| `max_move` | int | 0 | `Options::setGuideCalibrationBacklash` |
| `two_axis` | bool | false | `Options::setTwoAxisEnabled` |
| `square_size` | bool | false | `Options::setGuideAutoSquareSizeEnabled` |
| `calibrationBacklash` | bool | false | ⚠️ **also** calls `setGuideCalibrationBacklash` |
| `resetCalibration` | bool | false | `Options::setResetGuideCalibration` |
| `reuseCalibration` | bool | false | `Options::setReuseGuideCalibration` |
| `reverseCalibration` | bool | false | `Options::setReverseDecOnPierSideChange` |

> ⚠️ **Likely real bug in the upstream/fork source, not a doc error:** `calibrationBacklash`
> calls the *same setter* as `max_move` (`setGuideCalibrationBacklash`), overwriting the int
> value from `max_move` with a bool-as-int two lines later. Looks like copy-paste — don't
> assume `calibrationBacklash` does anything distinct from `max_move` until this is fixed.

**Response:** `guide_get_all_settings` (re-fetches and sends current settings after applying).

---

## 10. Align

### `align_solve` (`ALIGN_SOLVE`) — message.cpp:878
**Request:** none — `captureAndSolve()`. **Response:** none directly — watch
`new_align_state` (includes a `solution` field on success).

### `align_stop` (`ALIGN_STOP`) — message.cpp:897
**Request:** none — `abort()`. **Response:** none.

### `align_load_and_slew` (`ALIGN_LOAD_AND_SLEW`) — message.cpp:899

**Request** (two mutually exclusive shapes):
| Field | Type | Notes |
|---|---|---|
| `filename` | string | server-local file path, loaded directly |
| `data` | string | base64-encoded image bytes, decoded to a temp file (used only if `filename` absent) |
| `ext` | string | Optional (`"fits"`) — temp file extension, only relevant with `data` |

Uploads/solves the image, then slews to the solved position. **Response:** none directly —
watch `new_align_state`.

> Note: the Media channel's `align_load_and_slew`-*equivalent* upload path is actually via
> raw binary frames on `/media/ekos` (see §14) — this Message-channel command is the
> server-local-path/base64 variant; sending a raw binary frame on the Media channel is a
> separate, always-active upload path regardless of any text command.

### `align_manual_rotator_toggle` (`ALIGN_MANUAL_ROTATOR_TOGGLE`) — message.cpp:924
**Request:** `{"toggled": bool (false)}`. **Response:** none directly.

### `align_manual_rotator_status` (`ALIGN_MANUAL_ROTATOR_STATUS`) — **server push only**

No request handler — only `sendManualRotatorStatus` (message.cpp:2731):
`{"currentPA": double, "targetPA": double, "threshold": double}`.

### `align_set_astrometry_settings` (`ALIGN_SET_ASTROMETRY_SETTINGS`) — message.cpp:890

**Request:** `{"threshold": int (0)}`, `{"rotator_control": bool (false)}`,
`{"scale": bool (false)}`, `{"position": bool (false)}` — writes directly to global
`Options` (separate from the widget-reflection settings path below). **Response:** none.

### `align_get_all_settings` / `align_set_all_settings` — message.cpp:888, 882

Same reflection pattern (`QComboBox`/`QDoubleSpinBox`/`QSpinBox`/`QCheckBox`/`QRadioButton`
children of the Align widget tree). **Live-verified complete field list** (this session):
`FlipRotationNotAllowed`, `alignAccuracyThreshold`, `alignBinning`, `alignDarkFrame`,
`alignExposure`, `alignFilter`, `alignGain`, `alignISO`, `alignSettlingTime`,
`alignUseCurrentFilter`, `apertureShape`, `autoDownsample`, `cleanCheckBox`, `convFilter`,
`defaultPathSelector`, `downsample`, `fwhm`, `indexLocations`, `index_4107`…`index_4119`,
`index_4200`…`index_4219`, `index_5200`…`index_5206` (astrometry index-file checkboxes),
`inParallel`, `kcfg_AstrometryAutoUpdateImageScale`, `kcfg_AstrometryAutoUpdatePosition`,
`kcfg_AstrometryDifferentialSlewing`, `kcfg_AstrometryDynamicThreshold`,
`kcfg_AstrometryFlipRotationAllowed`, `kcfg_AstrometryImageScaleHigh`,
`kcfg_AstrometryImageScaleLow`, `kcfg_AstrometryImageScaleUnits`, `kcfg_AstrometryRadius`,
`kcfg_AstrometryRotatorThreshold`, `kcfg_AstrometrySolverOverlay`,
`kcfg_AstrometrySolverWCS`, `kcfg_AstrometryTimeout`, `kcfg_AstrometryUseImageScale`,
`kcfg_AstrometryUsePosition`, `kcfg_PAHAutoChangeDirection`, `kcfg_PAHAutoPACCorrection`,
`kcfg_PAHAutoPark`, `kcfg_PAHCorrectionTimeout`, `kcfg_PAHSuccessThreshold`,
`localSolverR`, `multiAlgo`, `nothingR`, `opticalTrainCombo`, `optionsProfile`,
`optionsProfileGroup`, `pAHDirection`, `pAHExposure`, `pAHManualSlew`, `pAHMountSpeed`,
`pAHRefreshAlgorithm`, `pAHRotation`, `remoteSolverR`, `resort`, `slewR`, `syncR`.

(The extra `kcfg_Astrometry*`/`kcfg_PAH*`/`index_*` fields come from embedded Options
sub-pages instantiated as children of the Align widget tree — not part of `align.ui`
itself, but reachable via the same `findChildren` reflection.) Get is debounced.

### `align_set_file_extension` (`ALIGN_SET_FILE_EXTENSION`) — **Media channel, not here**

See §14 — this command is dispatched from `media.cpp:139`, not `processAlignCommands`.
There's a real quirk: it stores an `extension` member that is **never actually read** —
the real upload path (`Media::onBinaryReceived`) sources the extension from the binary
frame's own header instead, shadowing the member with a local variable of the same name.
Sending this command has no observable effect on subsequent uploads.

---

## 11. Polar Alignment Assistant

### `polar_start` / `polar_stop` — message.cpp:1105, 1109
**Request:** none each. **Response:** none directly — watch `new_polar_state` stream.

### `polar_refresh` (`PAH_REFRESH`) — message.cpp:1113
**Request:** `{"value": double (1)}` — refresh duration. **Response:** none directly.

### `polar_set_algorithm` (`PAH_SET_ALGORITHM`) — message.cpp:1118
**Request:** `{"value": int (1)}` — cast to `RefreshAlgorithm` enum. **Response:** none.

### `polar_reset_view` (`PAH_RESET_VIEW`) — message.cpp:1124
**Request:** none — emits internal `resetPolarView()`. **Response:** none.

### `polar_set_crosshair` (`PAH_SET_CROSSHAIR`) — message.cpp:1128
**Request:** `{"x": double (0), "y": double (0)}` — fractional position (zoom/offset-adjusted
if a bounding rect is active). **Response:** none.

### `polar_star_select_done` (`PAH_SELECT_STAR_DONE`) — message.cpp:1150
**Request:** none. **Dead/no-op** — code comment: "removed from desktop PAA, nothing to
do." Kept for wire compatibility only.

### `polar_refreshing_done` (`PAH_REFRESHING_DONE`) — message.cpp:1156
**Request:** none — `stopPAHProcess()`. **Response:** none.

### `polar_slew_done` (`PAH_SLEW_DONE`) — message.cpp:1160
**Request:** none — `setPAHSlewDone()`. **Response:** none.

### `polar_set_zoom` (`PAH_PAH_SET_ZOOM`) — message.cpp:1164
**Request:** `{"scale": double (0)}` — `align->setAlignZoom(scale)`. **Response:** none.

**Status pushes** (`new_polar_state`, scattered across several functions):
- `{"stage": string}` · `{"message": string, HTML stripped}` ·
  `{"vector": {"center_x","center_y","mag","pa","error","azError","altError"}}` ·
  `{"updatedError","updatedAZError","updatedALTError"}` · `{"enabled": bool}`

---

## 12. Scheduler

### `scheduler_get_jobs` (`SCHEDULER_GET_JOBS`) — message.cpp:969

**Request:** none. **Response:** `{"jobs": [<job>, ...]}` — each `SchedulerJob::toJson()`:

| Field | Type | Notes |
|---|---|---|
| `name` | string | |
| `pa` | double | position angle |
| `targetRA` | double | hours, J2000 |
| `targetDEC` | double | degrees, J2000 |
| `state` | int | `SchedulerJob::JOBStatus` enum |
| `stage` | int | `SchedulerJob::JOBStage` enum |
| `sequenceCount` | int | |
| `completedCount` | int | |
| `minAltitude`, `minMoonSeparation`, `maxMoonAltitude` | double | |
| `repeatsRequired`, `repeatsRemaining` | int | |
| `inSequenceFocus` | bool | |
| `startupTime`, `completionTime`, `stopTime` | string | ISO date-time or literal `"--"` if invalid |
| `altitude` | double | computed live at serialize time |
| `altitudeFormatted`, `startupFormatted`, `endFormatted` | string | pre-formatted display strings |
| `sequence` | string | path to the `.esq` file |

### `scheduler_add_jobs` (`SCHEDULER_ADD_JOBS`) — message.cpp:973

**Request:** none — adds a job from whatever's currently in the Scheduler's own form
fields (see settings below), not from data passed in this call. **Response:** none
directly — follow with `scheduler_get_jobs`.

### `scheduler_remove_jobs` (`SCHEDULER_REMOVE_JOBS`) — message.cpp:977
**Request:** `{"index": int (0)}` — zero-based. **Response:** none.

### `scheduler_get_all_settings` / `scheduler_set_all_settings` — message.cpp:982

Same reflection pattern. Field set from `scheduler.ui`: `asapConditionR`, `epochCB`,
`errorHandlingDontRestartButton`, `errorHandlingRescheduleErrorsCB`,
`errorHandlingRestartImmediatelyButton`, `errorHandlingRestartQueueButton`,
`errorHandlingStrategyDelay`, `executionSequenceLimit`, `fitsEdit`, `groupEdit`,
`leadFollowerSelectionCB`, `nameEdit`, `opticalTrainCombo`, `positionAngleSpin`,
`schedulerAlignStep`, `schedulerAltitude`, `schedulerAltitudeValue`,
`schedulerCompleteSequences`, `schedulerFocusStep`, `schedulerGuideStep`,
`schedulerHorizon`, `schedulerMoonAltitude`, `schedulerMoonAltitudeMaxValue`,
`schedulerMoonSeparation`, `schedulerMoonSeparationValue`, `schedulerPostShutdownScript`,
`schedulerPostStartupScript`, `schedulerPreShutdownScript`, `schedulerPreStartupScript`,
`schedulerProfileCombo`, `schedulerRepeatEverything`, `schedulerRepeatSequences`,
`schedulerRepeatSequencesLimit`, `schedulerShutdownEnabled`, `schedulerStartupEnabled`,
`schedulerTrackStep`, `schedulerTwilight`, `schedulerUntil`, `schedulerUntilTerminated`,
`schedulerUntilValue`, `sequenceEdit`, `startupTimeConditionR`, `startupTimeEdit`. Plus
(if instantiated as children — verify live if these matter) embedded Options-page keys:
`kcfg_AlignCheckFrequency`, `kcfg_AlignCheckThreshold`, `kcfg_ForceAlignmentBeforeJob`,
`kcfg_RealignAfterCalibrationFailure`, `kcfg_ResetMountModelBeforeJob`,
`kcfg_ResetMountModelOnAlignFail`, `kcfg_DawnOffset`, `kcfg_DuskOffset`, `kcfg_LeadTime`,
`kcfg_PreDawnTime`, `kcfg_PreemptiveShutdown`, `kcfg_PreemptiveShutdownTime`,
`kcfg_SchedulerSafetyMonitorConnectionString`, `kcfg_SchedulerWeather`,
`kcfg_SchedulerWeatherGracePeriod`, `kcfg_SchedulerWeatherShutdownDelay`,
`kcfg_GreedyScheduling`, `kcfg_RememberJobProgress`, `kcfg_ShutdownScriptTerminatesINDI`,
`kcfg_StopEkosAfterShutdown`. Get is debounced.

### `scheduler_save_file` (`SCHEDULER_SAVE_FILE`) — message.cpp:992
**Request:** `{"filepath": string}`. **Response:** only sent on success — payload = raw
file contents as UTF-8 string. Silent on failure.

### `scheduler_save_sequence_file` (`SCHEDULER_SAVE_SEQUENCE_FILE`) — message.cpp:1004
**Request:** `{"filedata": string}` (optional — nothing written if absent), `{"path": string}`
(required if `filedata` present — resolved relative to `QDir::homePath()`).
**Response:** `{"result": bool, "path": string}` (`path` empty if `filedata` wasn't sent).

### `scheduler_load_file` (`SCHEDULER_LOAD_FILE`) — message.cpp:1027
**Request:** `{"filepath": string}` (server-local absolute path) or `{"filedata": string}`
(written to temp file if `filepath` empty; if both present, `filepath` treated as
home-relative). **Response:** `{"result": bool}` + `{"path": string}` if successful & non-empty.

### `scheduler_start_job` (`SCHEDULER_START_JOB`) — message.cpp:1081
**Request:** none — `toggleScheduler()`. **This is a toggle**, not exclusively "start" — if
already running, the same command stops it. **Response:** none directly — watch
`new_scheduler_state`.

### `scheduler_import_mosaic` (`SCHEDULER_IMPORT_MOSAIC`) — message.cpp:1085

**Request** (forwarded to `FramingAssistantUI::importMosaic`):
| Field | Type | Required | Notes |
|---|---|---|---|
| `csv` | string | Required | CSV: position angle + RA/Dec per panel + center coords |
| `sequence` | string | Required | path to `.esq` file used for every panel job |
| `target` | string | Required | sanitized for job/file names |
| `directory` | string | Required | output jobs directory |
| `track`, `focus`, `align`, `guide` | bool | Optional (false) | scheduler step toggles |
| `completionCondition`, `completionConditionArg` | string | Optional (empty) | |

**Response:** on success, triggers `scheduler_get_jobs` push with the new panel jobs (not a
dedicated reply). On failure, a `new_notification` event fires instead — no direct reply either way.

---

## 13. DSLR

### `dslr_set_info` (`DSLR_SET_INFO`) — message.cpp:1492
**Request:** `{"model": string, "width": int, "height": int, "pixelw": double, "pixelh": double}` — all required. Only applied if a capture module exists.
**Response:** `get_dslr_lenses` (full list — a blanket refresh, unrelated data but sent anyway).

### `dslr_set_mode` (`DSLR_SET_MODE`)

Present in `commands.h`/dispatch; not separately broken out by extraction — check
`processDSLRCommands` directly if needed.

### `dslr_get_info` (`DSLR_GET_INFO`) — **server push only**

No client-request handler in `processDSLRCommands`. `Message::requestDSLRInfo`
(message.cpp:2476, `sendResponse(commands[DSLR_GET_INFO], cameraName)`) is wired via Qt
signal from `manager.cpp:3636` — fired internally when a DSLR camera's info is needed/changes,
not something a client requests directly.

### `get_dslr_lenses` (`GET_DSLR_LENSES`) — message.cpp:206 (top-level)

**Request:** none. **Response** (`sendDSLRLenses`, message.cpp:422): bare array, each
`OAL::DSLRLens::toJson()`: `{"id", "model", "vendor", "name", "focal_length", "focal_ratio"}`.

### `dslr_add_lens` (`DSLR_ADD_LENS`) — message.cpp:1503
**Request:** `{"model", "vendor"}` (strings) + `{"focal_length", "focal_ratio"}` (doubles) — all required. **Response:** `get_dslr_lenses`.

### `dslr_update_lens` (`DSLR_UPDATE_LENS`) — message.cpp:1512
**Request:** same as `dslr_add_lens` plus `{"id": string}`. **Response:** `get_dslr_lenses`.

### `dslr_delete_lens` (`DSLR_DELETE_LENS`) — message.cpp:1508
**Request:** `{"id": string}`. **Response:** `get_dslr_lenses`.

---

## 14. Raw INDI Device Access

All commands read `payload["device"]` first; device not found → silent no-op (except the
unsubscribe-all special case below).

### `device_get` (`DEVICE_GET`) — message.cpp:1698

**Request:** `{"device": string}` (required), `{"compact": bool}` (optional, **default
`false`** — note this differs from `device_property_get`'s default of `true`).
**Response:** `{"device": string, "properties": [<property JSON>, ...]}` — one entry per
INDI property the device has. **BLOB properties are silently skipped.**

### `device_property_get` (`DEVICE_PROPERTY_GET`) — message.cpp:1686

**Request:** `{"device", "property"}` (strings, required), `{"compact": bool (true)}`.
**Response:** same command, property JSON (shape below) — only sent if the property is found.

### `device_property_set` (`DEVICE_PROPERTY_SET`) — message.cpp:1693

**Request:** `{"device", "property"}` (required) + `{"elements": [...]}` (required), shape
depends on property type:
- **Switch:** `{"name": string, "state": int}` (`ISState`: 0=OFF, 1=ON). For
  `ISR_1OFMANY`/`ISR_ATMOST1` rule types, the whole vector is reset before applying.
- **Number:** `{"name": string, "value": double}` — if `value` isn't parseable as a plain
  double, falls back to sexagesimal parsing (`f_scansexa`), so `"value": "12:30:00"` also works.
- **Text:** `{"name": string, "text": string}`.
- **BLOB: unimplemented** (`// TODO` in source) — cannot set BLOB properties this way.

**Response:** none — the change arrives via the normal property-update push mechanism, only
for properties you've subscribed to.

### `device_property_subscribe` (`DEVICE_PROPERTY_SUBSCRIBE`) — message.cpp:1718

**Request:** `{"device": string}` (required), `{"properties": [string,...]}` (optional,
exact names) or `{"groups": [string,...]}` (optional, INDI group names e.g.
`"Main Control"` — subscribes every property in those groups). If neither given, **all**
properties on the device are subscribed.

**Response:** none directly — subscribed property updates are coalesced (deduped,
timer-debounced) and pushed automatically as `device_property_get`-tagged messages
(`sendPendingProperties`, message.cpp:2853), always **compact** JSON.

### `device_property_unsubscribe` (`DEVICE_PROPERTY_UNSUBSCRIBE`) — message.cpp:1753

**Request:** same shape as subscribe — selectively removes, or removes all for that device
if neither `properties` nor `groups` given. **Special case:** `{"device": ""}` clears
**all** subscriptions for the client regardless of anything else in the payload.
**Response:** none.

### `device_restart` (`DEVICE_RESTART`) / `device_blob_get` (`DEVICE_BLOB_GET`) — ⚠️ **NOT IMPLEMENTED**

Both declared in `commands.h`, no handler anywhere. `GenericDevice::getJSONBLOB()` exists
and *would* produce `{"property", "element", "size", "data" (base64)}` but nothing in the
dispatch ever calls it — BLOB properties are unreachable via the wire protocol entirely
(also confirmed unreachable via `device_get`/`device_property_get`/`device_property_set` above).

### `device_message` (`DEVICE_MESSAGE`) — **server push only**, message.cpp:2811

Sent automatically for device log lines matching `[INFO]`/`[WARNING]`/`[ERROR]` (gated by
`Options::ekosRemoteNotifications()`): `{"device": string, "message": <full log line>}`.

### Property JSON shapes (shared by `device_property_get` and `device_get`'s `properties[]`)

**Switch:**
```json
{"device": "...", "name": "...", "state": <int IPState>,
 "switches": [{"name": "...", "state": <int ISState>}, ...],
 "label": "...", "group": "...", "perm": <int>, "rule": <int ISRule>  // non-compact only
}
```
**Number:**
```json
{"device": "...", "name": "...", "state": <int IPState>,
 "numbers": [{"name": "...", "value": <double>}, ...],
 // non-compact per-element adds "label","min","max","step","format"; top-level adds "label","group","perm"
}
```
**Text:**
```json
{"device": "...", "name": "...", "state": <int IPState>,
 "texts": [{"name": "...", "text": "..."}, ...]
 // non-compact adds per-element "label"; top-level "label","group","perm"
}
```
**Light** (read-only, no set equivalent):
```json
{"device": "...", "name": "...", "state": <int IPState>,
 "lights": [{"name": "...", "state": <int>}, ...]
 // non-compact adds per-element "label"; top-level "label","group"
}
```

---

## 15. Dark Library

### `dark_library_start` / `dark_library_stop` — message.cpp:1615, 1631
**Request:** none each. **Response:** none.

### `dark_library_get_all_settings` / `dark_library_set_all_settings` — message.cpp:1623, 1617

Same generic reflection pattern (`QComboBox`/`QDoubleSpinBox`/`QSpinBox`/`QCheckBox`
children of the Dark Library panel). No fixed field list documented — call
`dark_library_get_all_settings` once to discover it empirically, same as other
`*_get_all_settings` commands.

### `dark_library_get_defect_settings` (`DARK_LIBRARY_GET_DEFECT_SETTINGS`) — message.cpp:1625

**Request:** none. **Response:**
| Field | Type |
|---|---|
| `masterTime` | string |
| `masterDarks` | string, pipe (`\|`)-joined list |
| `masterExposure`, `masterTempreture` (sic), `masterMean`, `masterMedian`, `masterDeviation` | string |
| `hotPixelsEnabled`, `coldPixelsEnabled` | bool |

### `dark_library_set_camera_presets` (`DARK_LIBRARY_SET_CAMERA_PRESETS`) — message.cpp:1627
**Request:** `{"optical_train": string}` (required, empty ok), `{"isDarkPrefer": bool}`,
`{"isDefectPrefer": bool}` (both optional, default current UI state). **Response:** none.

### `dark_library_get_camera_presets` (`DARK_LIBRARY_GET_CAMERA_PRESETS`) — message.cpp:1640
**Request:** none. **Response:** `{"optical_train", "preferDarksRadio" (bool),
"preferDefectsRadio" (bool), "fileName"}`.

### `dark_library_get_masters_image` (`DARK_LIBRARY_GET_MASTERS_IMAGE`) — message.cpp:1635
**Request:** `{"row": int}` (required) — calls `loadIndexInView(row)`, changing internal
selection. **No response sent from this handler** — any resulting image push happens
elsewhere, not verified.

### `dark_library_set_defect_pixels` (`DARK_LIBRARY_SET_DEFECT_PIXELS`) — message.cpp:1644
**Request:** `{"hotSpin": int, "coldSpin": int}` (required, 0 if absent), `{"hotEnabled",
"coldEnabled": bool}` (optional, default current UI checkbox state). **Response:** none —
also triggers `setDefectMapEnabled(true)` + an internal save-button click.

### `dark_library_save_map` (`DARK_LIBRARY_SAVE_MAP`) — message.cpp:1648
**Request:** none — clicks the save-map button. **Response:** none.

### `dark_library_set_defect_frame` (`DARK_LIBRARY_SET_DEFECT_FRAME`) — message.cpp:1652

**Request:** payload not read at all. ⚠️ **Despite the name, this always *disables* the
defect map** (`setDefectMapEnabled(false)`) — don't expect it to accept an
enable/disable flag. **Response:** none.

### `dark_library_get_view_masters` (`DARK_LIBRARY_GET_VIEW_MASTERS`) — message.cpp:1656

**Request:** none. **Response:** JSON array, one object per masters-table row:
`{"camera", "binX", "binY", "temperature" (double), "duaration"` (sic, double)`, "ts"
(string), "gain"` (int, only if `>= 0`)`, "iso"` (string, only if non-empty)`}`.

### `dark_library_clear_masters_row` (`DARK_LIBRARY_CLEAR_MASTERS_ROW`) — message.cpp:1660
**Request:** `{"row": int}` (required). **Response:** none.

---

## 16. Live Stacking

### `livestacker_initialize` (`LIVESTACKER_INITIALIZE`) — message.cpp:3151

**Request:** none. Closes any existing live-stacker viewer, creates a new `FITSViewer`,
calls `stack()`. **Response:** `new_livestacker_state` →
`{"state": "initialized"}` or `{"state": "error", "message": "Failed to create FITS Viewer"}`.

### `livestacker_set_all_settings` (`LIVESTACKER_SET_ALL_SETTINGS`) — message.cpp:3174

**Request:** free-form key:value merge (`m_LiveStackerSettings[key] = value` — **partial
updates do not clear existing keys**). Recognized keys, read back on `livestacker_start`:

| Field | Type | Default |
|---|---|---|
| `calcSNR` | bool | true |
| `alignMethod` | int | 0 (`LiveStackAlignMethod` enum) |
| `stackingMethod` | int | 0 (`LiveStackStackingMethod` enum) |
| `downscale` | int | 0 (`LiveStackDownscale` enum) |
| `numInMem` | int | 10 |
| `weighting` | int | 0 (`LiveStackFrameWeighting` enum) |
| `lowSigma` | double | 2.0 |
| `highSigma` | double | 3.0 |
| `postProcess` | bool | false |
| `sharpenAmt`, `denoiseAmt`, `deconvAmt`, `gradientAmt` | double | 0.0 |
| `masterDarkPath`, `masterFlatPath` | string | empty — wrapped in a 1-element vector internally |
| `stackingDirectory` | string | empty (start fails if unset) — auto-resolved from the active capture job's target in non-looping mode |
| `looping` | bool | false — selects looping/framing vs active-sequence frame-feeding |
| `outputDirectory` | string | empty — where stacked output is written |

**Response:** `livestacker_get_all_settings`, payload = full merged map.

### `livestacker_get_all_settings` (`LIVESTACKER_GET_ALL_SETTINGS`) — message.cpp:3183
**Request:** none. **Response:** current `m_LiveStackerSettings` as-is, no schema enforced.

### `livestacker_start` (`LIVESTACKER_START`) — message.cpp:3187

**Request:** none (uses previously-set settings). **Response:** `new_livestacker_state` →
one of `{"state": "error", "message": "LiveStacker not initialized"}`,
`{"state": "error", "message": "No active view"}`,
`{"state": "error", "message": "No stacking directory specified"}`, or
`{"state": "started"}`.

Ongoing progress: `{"state": "stacking", "ok" (bool), "frames_stacked" (int),
"total_frames" (int), "mean_snr", "min_snr", "max_snr" (double)}` (`sendLiveStackerProgress`,
message.cpp:3403), then `{"state": "complete"}` (`sendLiveStackerComplete`, message.cpp:3421).
In non-looping mode, a job-change watcher auto-restarts the stacker (re-resolved
`stackingDirectory`) when the active capture job's target/filter changes — no client action
needed, but expect fresh state pushes if that happens mid-session.

### `livestacker_stop` (`LIVESTACKER_STOP`) — message.cpp:3330
**Request:** none. **Response:** `new_livestacker_state` → `{"state": "stopped"}` (only if
a viewer exists).

### `livestacker_close` (`LIVESTACKER_CLOSE`) — message.cpp:3367
**Request:** none. **Response:** `new_livestacker_state` → `{"state": "closed"}`. Also
destroys the FITS viewer entirely (unlike `stop`, which leaves it open for a future `start`).

---

## 17. Artificial Horizon

### `artificial_horizon_import` (`ARTIFICIAL_HORIZON_IMPORT`) — message.cpp:3577

**Request:** `{"data": string}` (required — silent no-op if absent/empty). **Not JSON** —
despite an unused `QJsonDocument::fromJson` parse attempt in the code, the real format is
KStars' native horizon-file text, line by line (blank lines and `#`-comments skipped):
- First non-comment line: `Ceiling <name>` or `Horizon <name>` (case-sensitive keyword).
  `Ceiling` sets a ceiling region instead of a floor.
- Every following line: exactly two whitespace-separated tokens, `<azimuth> <altitude>`,
  parsed via `dms::fromString(..., true)` (sexagesimal-capable).
- Needs ≥2 valid point lines and a non-empty name, else the import silently no-ops.

**Response:** none — but replaces any existing region of the same name, force-enables
ground display if it was off, saves, and forces a sky-map repaint.

### `artificial_horizon_toggle` (`ARTIFICIAL_HORIZON_TOGGLE`) — message.cpp:3655

**Request:** `{"enabled": bool (false)}` (required), `{"region": string}` (optional, empty
= toggle **all** regions; named = toggle just that one). **Response:** none — saves config,
forces repaint.

### `artificial_horizon_get` (`ARTIFICIAL_HORIZON_GET`) — message.cpp:3675

**Request:** none. **Response:** JSON **array** (not object):
```json
[{"name": "...", "enabled": <bool>, "ceiling": <bool>,
  "points": [{"az": <double deg>, "alt": <double deg>}, ...]}, ...]
```

---

## 18. File Operations

### `file_default_path` (`FILE_DEFAULT_PATH`) — message.cpp:2314

**Request:** `{"type": int}` (optional, `0` default) — cast to `QStandardPaths::StandardLocation`.
**Response:** same command, payload is a plain string — the resolved absolute path.

### `file_directory_operation` (`FILE_DIRECTORY_OPERATION`) — message.cpp:2319

**Request (common):** `{"path": string, "operation": string}` — `operation` one of
`"create"`, `"remove"`, `"list"`, `"exists"`; anything else is silently ignored (no response).

- **`"create"`** — `QDir().mkpath(path)`. Response: `{"result": bool, "operation": "create"}`.
- **`"remove"`** — `QDir(path).removeRecursively()`. Response: `{"result": bool, "operation": "remove"}`.
- **`"list"`** — extra optional fields: `{"namedFilters": string ("*")}` (comma-split name
  filters, e.g. `"*.fits,*.jpg"`), `{"filters": int (QDir::NoFilter)}` (`QDir::Filters`
  bitmask), `{"sort": int (QDir::NoSort)}` (`QDir::SortFlags`). Response:
  `{"result": bool, "operation": "list", "payload": [<entry>, ...]}` where each entry is
  `{"name", "path" (absolute parent dir), "size" (int64), "isFile" (bool), "creation"
  (int64 unix seconds), "modified" (int64 unix seconds)}`.
- **`"exists"`** — `QDir(path).exists()`. Response: `{"result": bool, "operation": "exists"}`.

---

## 19. Filter Manager

### `fm_get_data` (`FM_GET_DATA`) — message.cpp:1599
**Request:** none — silent no-op if no capture module/filter manager exists.
**Response:** `FilterManager::toJSON()` (shape defined in `capture/filtermanager.cpp`, not this file).

### `fm_set_data` (`FM_SET_DATA`) — message.cpp:1604
**Request:** whole payload forwarded to `manager->setFilterData(payload)` (shape not in this file).
**Response:** none directly.

---

## 20. Options & Dialogs

### `option_set` (`OPTION_SET`) — message.cpp:1438

**Request:** `{"options": [{"name": string, "value": any}, ...]}` (required) — each applied
via `Options::self()->setProperty(name, value)`, saved to disk, emits `optionsUpdated()`.
**Response:** none.

### `option_get` (`OPTION_GET`) — message.cpp:1447

**Request:** `{"options": [{"name": string}, ...]}` (required, only `name` read per entry).
**Response:** `option_get`, array of `{"name": string, "value": any}` echoing each requested
option's current value (`value` omitted/null if the named `Options` property doesn't exist).

### `dialog_get_response` (`DIALOG_GET_RESPONSE`) — message.cpp:2750 (`processDialogResponse`)

**Request:** `{"button": string}` (optional, empty default) — forwarded to
`KSMessageBox::Instance()->selectResponse(...)`. **Response:** none directly — this answers
a `dialog_get_info` push that the server sent earlier.

### `dialog_get_info` (`DIALOG_GET_INFO`) — **server push only**

Sent (`sendDialog`, message.cpp:2490) whenever a modal `KSMessageBox` dialog appears
server-side. No client-invocable request exists for this — only the response above.

---

## 21. Astronomy Library (read-only lookups)

Dispatched via the `"astro_"` prefix (`processAstronomyCommands`, message.cpp:1794) —
**except** `astro_get_objects_image` and `astro_get_skypoint_image`, which live on the
**Media channel** (see §14/§22), not here.

Commands accepting `"jd"` (Julian Date) temporarily override KStars' clock to that date
**only if Ekos isn't currently running** — preview "what's visible on date X" without
disturbing a live imaging session's clock.

### `astro_get_almanac` (`ASTRO_GET_ALMANC`) — message.cpp:1796

**Request:** none. **Response:** `{"SunRise","SunSet" (time), "SunMaxAlt","SunMinAlt"
(double), "MoonRise","MoonSet" (time), "MoonPhase","MoonIllum" (double), "Dawn","Dusk"
(astronomical twilight times)}` — computed for local midnight today at the configured geo location.

### `astro_get_names` (`ASTRO_GET_NAMES`) — message.cpp:1822

**Request:** none. **Response:** flat array of strings — every known object's primary
name plus alternate designations (deduped, case-insensitive sorted). Covers stars, catalog
stars, planets, moon, comets, asteroids, supernovae, satellites, all DSO catalog objects.

### `astro_get_designations` (`ASTRO_GET_DESIGNATIONS`) — message.cpp:1849

**Request:** none. **Response:** array over DSO catalog objects only:
`[{"primary": string, "designations": [string, ...]}, ...]`.

### `astro_get_location` (`ASTRO_GET_LOCATION`) — message.cpp:1866

**Request:** none. **Response:** `{"name", "longitude" (deg), "latitude" (deg),
"elevation", "tz" (current tz offset), "tz0" (standard tz offset)}`.

### `astro_search_objects` (`ASTRO_SEARCH_OBJECTS`) — message.cpp:1882

**Request** — all optional:
| Field | Type | Default | Notes |
|---|---|---|---|
| `jd` | double | — | clock-override, see above |
| `type` | int | 8 (`GALAXY`) | see `SkyObject::TYPE` table below |
| `direction` | int | 4 (All) | 0=North, 1=East, 2=South, 3=West, 4=All — filters by azimuth quadrant |
| `maxMagnitude` | double | 10 | objects with valid magnitude greater than this excluded (invalid/NaN magnitude always passes) |
| `minAlt` | double | 15 | degrees, must be above this |
| `minDuration` | int | 3600 | seconds must stay above `minAlt` until next dawn, else excluded |
| `minFOV` | double | 0 | arcmin, DSO-only filter on catalog major axis |

`SkyObject::TYPE` values actually handled (others → empty result): `STAR=0`,
`CATALOG_STAR=1`, `PLANET=2`, `MOON=12` (shares planet branch), `COMET=9`, `ASTEROID=10`,
`OPEN_CLUSTER=3`, `GLOBULAR_CLUSTER=4`, `GASEOUS_NEBULA=5`, `PLANETARY_NEBULA=6`,
`GALAXY=8`, `SUPERNOVA=20` (auto-enables `Options::showSupernovae()`), `SATELLITE=19`
(auto-enables `Options::showSatellites()`).

**Response:** flat array of object name strings (magnitude-sorted, deduped) — not full
data. Follow with `astro_get_object_info`/`astro_get_objects_info` per name.

### `astro_get_object_info` (`ASTRO_GET_OBJECT_INFO`) — message.cpp:2128

**Request:** `{"object": string}` (required), `{"exact": bool (false)}`.
**Response:** found → `{"name", "designations" (array), "magnitude" (double), "ra0" (hours,
J2000), "de0" (degrees, J2000), "ra" (hours, current epoch), "de" (degrees, current epoch),
"object": true}`. Not found → `{"name": <name>, "object": false}`.

### `astro_get_objects_info` (`ASTRO_GET_OBJECTS_INFO`) — message.cpp:2161

**Request:** `{"jd": double}` (optional), `{"names": [string,...]}` (required),
`{"exact": bool (false)}`. **Response:** array, one entry per resolved name (unresolved
silently skipped) — same fields as `astro_get_object_info` (minus `"object"`), plus for DSO
catalog objects: `"a"`, `"b"` (major/minor axis), `"pa"` (position angle).

### `astro_get_objects_observability` (`ASTRO_GET_OBJECTS_OBSERVABILITY`) — message.cpp:2209

**Request:** same as `astro_get_objects_info`. **Response:** array of
`{"name", "az" (deg), "alt" (deg), "ha" (hours)}` for current (or `jd`-overridden) sidereal time.

### `astro_get_objects_riseset` (`ASTRO_GET_OBJECTS_RISESET`) — message.cpp:2253

**Request:** `{"jd": double}` (optional), `{"names": [string,...]}` (required),
`{"exact": bool (false)}`, `{"days": int (0)}` (additional future days to include).
**Response:** array, one entry per name:
```json
{"name": "...", "date": "yyyy-MM-dd",
 "rise": "HH:MM" | "Circumpolar" | "Never rises",
 "set": "HH:MM" | "Circumpolar" | "Never rises",
 "transit": "HH:MM",
 "altitudes": [<49 doubles, every 30min from -12h to +12h around local midnight>],
 "days": [<same shape minus "days">, ...]  // only if days > 0
}
```

---

## 22. Media Channel (`/media/ekos`)

**No `set_client_state` gate on this channel** — connecting is sufficient to receive
frames. The only gate is `set_blobs` (below), combined with connection state. Confirmed by
exhaustive grep: no client-state flag analogous to the Message channel exists here.

**Routing:** `NodeManager` creates two `Node`s at construction (`"message"`, `"media"`) and
routes each incoming WebSocket by exact path match (`/message/ekos` vs `/media/ekos`);
anything else is rejected and the socket closed. Shared plumbing with the Message channel,
not Media-specific.

**On last-client disconnect** (`Media::onDisconnected`): resets `m_sendBlobs` back to
`true` and deletes all temp files recorded in `temporaryFiles`. `set_blobs: false` does
**not** persist across a full disconnect/reconnect — a reconnecting client always starts
with blobs enabled again.

### Binary frame format

```
[ 512-byte JSON metadata header, null-padded ][ JPEG image bytes ]
```
Always read exactly the first 512 bytes, strip trailing nulls, `QJsonDocument::fromJson`
that slice, then treat the rest as JPEG. Three producer paths build different header field
sets:

**Full header** (`Media::upload`, capture/preview images):
| Field | Type | Meaning |
|---|---|---|
| `resolution` | string `"WxH"` | pixel dimensions |
| `size` | string | human-readable byte size |
| `channels` | int | |
| `mean`, `median`, `stddev` | double | |
| `min`, `max` | double | only in the `FITSView`-based overload |
| `bin` | string `"XxY"` | |
| `bpp` | string | bits per pixel |
| `uuid` | string | frame-type tag, see below |
| `exposure`, `focal_length`, `aperture`, `gain` | string | from FITS header records |
| `pixel_size` | string | `%.4f` formatted |
| `shadows`, `midtones`, `highlights` | number | stretch params |
| `hasWCS` | bool | |
| `hfr` | double | |
| `view` | string | `view->objectName()`, only in `FITSView` overload |
| `ext` | string | always `"jpg"` |

**Reduced header** (align "+A" fast-preview path): `resolution`, `size`, `channels`,
`mean`, `median`, `stddev`, `bin`, `bpp`, `uuid` (always `"+A"`), `exposure`,
`focal_length`, `aperture`, `gain`, `pixel_size`, `ext`. No min/max/stretch/hasWCS/hfr/view.

**Minimal header** (live video frames): only `resolution` and `ext` — **no `uuid` field at
all** (video frames carry no frame-type tag).

**HIPS sky-image lookup header** (distinct shape, unrelated to capture header): `uuid`,
`name`, `zoom`, `resolution`, `bin` (always `"1x1"`), `fov_w`, `fov_h`, `ext`.

**Constants** (`media.h`): `METADATA_PACKET=512`, `HB_IMAGE_WIDTH=1920`,
`HB_IMAGE_QUALITY=90`, `HB_VIDEO_WIDTH=1280`, `HIPS_TILE_WIDTH`/`HIPS_TILE_HEIGHT=512`.
(`HB_VIDEO_QUALITY=64`, `HB_PAH_IMAGE_QUALITY=50`, `HB_PAH_VIDEO_QUALITY=24` are declared
but unused in this file — video actually uses `QImageWriter::setCompression(6)` instead.)

### `uuid` frame-type tags

| Tag | Meaning |
|---|---|
| `""` (a per-frame identifier, not literally empty) | regular capture preview |
| `"+A"` | align frame |
| `"+F"` | focus frame |
| `"+G"` | guide frame |
| `"+D"` | dark-library frame |
| `"hips_<md5>"` | HIPS object-image lookup (deterministic hash of level+zoom+name) |
| `"skypoint_hips"` | HIPS sky-point lookup (fixed, not per-request unique) |

**"Fast frame" scaling:** any tag starting with `+` gets scaled to `HB_IMAGE_WIDTH/2`
(960px) via `Qt::FastTransformation`, vs full 1920px `Qt::SmoothTransformation` otherwise.
⚠️ Applies uniformly to `+A`/`+F`/`+G`/`+D` despite a source comment claiming `+D` is
excepted — the code does **not** actually special-case it. Confirm independently if
precise dark-frame resolution matters to you.

### JSON commands on this channel

Flat if/else chain in `Media::onTextReceived` — no prefix-dispatch like the Message channel.

**`align_set_file_extension`** (`ALIGN_SET_FILE_EXTENSION`) — media.cpp:139: `{"ext":
string (empty default)}`. **Has no observable effect** — see §10's note; the real upload
path reads `ext` from the binary frame's own header instead.

**`set_blobs`** (`SET_BLOBS`) — media.cpp:141: payload is a **bare boolean**, not an
object — `{"type": "set_blobs", "payload": true}`, **not** `{"payload": {"value": true}}`.
Suppresses all outgoing binary frames when `false`.

**`astro_get_objects_image`** (`ASTRO_GET_OBJECTS_IMAGE`) — media.cpp:144: `{"names":
[string,...]}` (required), `{"level": int (5)}`, `{"zoom": number (20000)}`, `{"exact":
bool (false)}`. One binary frame per resolved name (unresolved silently skipped); planets/
moon render via external `xplanet` — if unavailable/misconfigured, that image just comes
back blank with no error.

**`astro_get_skypoint_image`** (`ASTRO_GET_SKYPOINT_IMAGE`) — media.cpp:213: `{"ra": number
(0, hours)}`, `{"de": number (0, degrees)}`, `{"level": int (5)}`, `{"zoom": number
(20000)}`, `{"width": number (512)}`, `{"height": number (512)}`. Exactly one binary frame;
`uuid` is always the fixed literal `"skypoint_hips"` — not unique per request, so a second
call while a first is still processing has no way to be correlated back.

### Binary uploads (align-solve)

`Media::onBinaryReceived` treats **any** binary frame received on this channel as an
align-solve image upload — strips the first 512 bytes as a header (reads only `ext`),
forwards the rest to `Align::loadAndSlew`, gated only on an Align module existing. There's
no separate "start" command — sending any raw binary frame here triggers a real plate-solve
attempt. **Never send arbitrary/test binary frames on this channel without expecting that.**

---

## Appendix A — Confirmed dead / unimplemented commands

Declared in `commands.h`, exhaustively grepped, no handler anywhere in `message.cpp` or `media.cpp`:

| Command | Notes |
|---|---|
| `mount_clear` | |
| `device_restart` | |
| `device_blob_get` | BLOB properties are unreachable via this protocol at all |
| `dome_park`, `dome_unpark`, `dome_goto`, `dome_stop` | Status monitoring (`new_dome_state`) still works |
| `cap_park`, `cap_unpark`, `cap_set_light` | Status monitoring (`new_cap_state`) still works |

## Appendix B — Server-push-only commands (not client-invocable)

`dialog_get_info`, `align_manual_rotator_status`, `train_configuration_requested`,
`profile_get_port_selection`, `device_message`, `dslr_get_info`, `capture_get_preview_label`.

## Appendix C — Known quirks / possible bugs worth independent confirmation

1. **`guide_set_calibration_settings`**: `calibrationBacklash` field calls the same setter
   (`setGuideCalibrationBacklash`) as `max_move`, overwriting it — looks like a copy-paste bug.
2. **`set_blobs`** (Media channel): payload is a bare bool, not `{"value": bool}` — easy to get wrong.
3. **`align_set_file_extension`** (Media channel): sets a member that's never read; the real
   upload path sources `ext` from the binary frame's own header instead.
4. **Media "fast frame" scaling**: a source comment says `+D` (dark-library) frames are
   excepted from fast/low-quality scaling; the code doesn't actually except them.
5. **`dark_library_set_defect_frame`**: name implies a toggle, but it unconditionally disables the defect map — payload isn't read.
6. **`profile_get`**: computes the named profile but never sends it back — dead on the response side.
7. **`invoke_method`**: `LongLong`/`ULongLong` args are narrowed to plain `int`/`uint` before
   being passed through — large 64-bit values will silently truncate.
8. **`*_get_all_settings` debouncing**: get-side replies for capture/focus/mount/align/
   guide/scheduler/dark-library settings are batched and delayed ~500ms via a shared timer
   that also triggers a KStars config disk write — don't assume a synchronous reply.
