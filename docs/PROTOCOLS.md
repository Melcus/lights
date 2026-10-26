# Device protocols

How Lights talks to each device. The Govee side follows Govee's published LAN API. The Elgato side is not documented anywhere: it was reverse engineered from Elgato Control Center 1.9.2 (`com.corsair.ControlCenter`) and verified against a Key Light Neo running firmware 1.0.6.

## Elgato Key Light Neo over USB

### Device

| Property | Value |
| --- | --- |
| Vendor ID | `0x0FD9` (Elgato) |
| Product ID | `0x00A0` (Key Light Neo) |
| Interface | HID, Consumer page `0x0C`, usage `0x01` |
| Reports | Report ID `0x02`, 511-byte vendor input and output reports (usage `0xFF00`) |

The HID report descriptor (`050c0901a1010a00ff150026ff00750896ff01850281020a00ff150026ff00750896ff0185029102c0`) declares nothing but a raw 511-byte pipe in each direction. Elgato runs its regular HTTP-style REST API through that pipe, so the JSON bodies are identical to the Wi-Fi Key Lights on port 9123.

The device can be opened non-exclusively, and every client receives every input report. Lights and Control Center can therefore run side by side, and each sees the replies to the other's requests.

### Report framing

Every report is 512 bytes including the report ID, zero padded:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 1 | Report ID, always `0x02` |
| 1 | 1 | Packet index, starting at 0 |
| 2 | 1 | Packet count |
| 3 | 1 | Kind (see below) |
| 4 | 2 | Payload length, little endian |
| 6 | n | Payload |

A message longer than 505 bytes is split across several reports with the same kind and increasing index. Control Center reserves one byte after the payload (a NUL terminator), which is why the limit is 505 rather than 506. Bytes after the declared length in input reports are stale firmware buffer contents and must be ignored.

| Kind | Direction | Meaning | Status |
| --- | --- | --- | --- |
| `0x03` | host to light | Request | Observed and verified |
| `0x00` | light to host | Response to a request | Observed |
| `0x08` | light to host | Change notification, sent to every host | Observed |
| `0x04` | host to light | Sent by Control Center when its internal "request" flag is false | Inferred from the serializer; purpose unknown, never needed |

### Messages

Requests are text: `<METHOD> <path>`, optionally followed by a space and a JSON body.

```
GET /elgato/lights
GET /elgato/accessory-info
PUT /elgato/lights {"lights":[{"on":1}],"numberOfLights":1}
```

Responses are bare JSON without the method or path, so their meaning comes from the shape of the body:

```
{"numberOfLights":1,"lights":[{"on":1,"brightness":30,"temperature":143}]}
```

Notifications repeat the request line followed by the current state. One arrives after any change, including changes made by another host:

```
GET /elgato/lights {"numberOfLights":1,"lights":[{"on":1,"brightness":30,"temperature":143}]}
```

Control Center parses notifications with the regular expression `/^([A-Z]+) ([^ ]+) (.*)$/`. Rejected requests answer with an error body, for example when brightness exceeds the power limit:

```
{"errors":[{"message":"Invalid parameters","code":-1}]}
```

The firmware accepts JSON keys in any order. Endpoints referenced by Control Center: `/elgato/lights`, `/elgato/lights/settings`, `/elgato/accessory-info`, `/elgato/identify`, `/elgato/battery-info`, `/elgato/ble/pairing` and `/elgato/firmware-update/{prepare,data,execute}`. Lights only uses the first and third.

### Values

| Field | Range | Notes |
| --- | --- | --- |
| `on` | 0 or 1 | |
| `brightness` | 3 to 100 | Capped by `power-info.maximumBrightness` from `/elgato/accessory-info`; higher values are rejected |
| `temperature` | 143 to 344 | Mireds: 143 is 7000 K, 344 is 2900 K. Elgato's apps show Kelvin rounded to 50 K |

`/elgato/accessory-info` reports the power situation, for example `"power-info":{"operationMode":1,"maximumBrightness":40}`. On a computer's USB port the Neo is limited to 40%; a 3 A USB-C supply allows full brightness.

### Evidence

Function addresses refer to the arm64 slice of `Elgato Control Center.app/Contents/MacOS/ControlCenter` version 1.9.2. The binary is stripped, so functions were located through the error strings they reference and read as disassembly.

| Address | Role | Key observation |
| --- | --- | --- |
| `0x100124b1c` | Encodes a `USBCommand` | Builds `[method, path].joined(" ")` with method GET, PUT or POST, appends `?query` and `" " + body`, then splits into packets of `{index, count, flag = 1}` once the message exceeds the report size minus 7 |
| `0x100125164` | Send loop | Packs index, count and flag into one word (`index + count << 8 + flag << 16`), serializes each packet, writes it, then waits on a semaphore with a timeout for the response |
| `0x100120c48` | Packet serializer | Writes `0x02, index, count, flag ? 3 : 4`, then the payload length as a little-endian `UInt16`, then the payload |
| `0x100127260` | HID writer | Pads to the device's maximum output report size and calls `IOHIDDeviceSetReport` with report type output |
| `0x1001297dc` | Inbound parser | Converts the report to a string and matches `/^([A-Z]+) ([^ ]+) (.*)$/` into method, endpoint and JSON |

Verification on the device: a `GET /elgato/accessory-info` framed this way returned the accessory info; an idempotent `PUT` returned the light state followed by a kind `0x08` notification; brightness, colour temperature and power changes were confirmed by reading the state back. The byte-level fixtures in `LightsKit/Tests` are taken from these captures.

## Govee LAN API

Govee documents this API; it must be enabled per device with the LAN Control switch in the Govee Home app.

| Step | Transport | Payload |
| --- | --- | --- |
| Discover | Multicast to `239.255.255.250:4001` | `{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}` |
| Status | Unicast to device `:4003` | `{"msg":{"cmd":"devStatus","data":{}}}` |
| Power | Unicast to device `:4003` | `{"msg":{"cmd":"turn","data":{"value":1}}}` |
| Brightness | Unicast to device `:4003` | `{"msg":{"cmd":"brightness","data":{"value":50}}}`, 1 to 100 |
| Colour or white | Unicast to device `:4003` | `{"msg":{"cmd":"colorwc","data":{"color":{"r":255,"g":0,"b":0},"colorTemInKelvin":0}}}` |

Devices send scan and status replies to UDP 4002 on the sender's address, from an ephemeral source port, so the client must listen on 4002 (and the macOS firewall must allow it). Commands are not acknowledged; state is read back with `devStatus`:

```
{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":27,"color":{"r":255,"g":255,"b":255},"colorTemInKelvin":4800}}}
```

`colorTemInKelvin` is 0 while the device shows an RGB colour. The Lyra (SKU H6072) covers 2200 K to 6500 K.

## Nanoleaf OpenAPI (Secretlab MAGRGB)

Nanoleaf documents this API for its own lights. The Secretlab MAGRGB is a Nanoleaf controller and speaks it too, with gaps. Everything below was observed on a MAGRGB XL: model `NL72S2`, firmware 4.0.0, hardware 1.3.0.

### Discovery

The light announces `_nanoleafapi._tcp` over Bonjour, port 16021. TXT keys: `eui64` (`0000808AF72DF9B2`, the only identifier that survives a factory reset), `id` (changes on reset), `md` (model) and `srcvers` (firmware). The service name changes on reset too ("Secretlab MAGRGB 6B4" afterwards), so Lights keys devices by `eui64` and resolves the service to an IPv4 address with a short TCP connection.

### Pairing

`POST /api/v1/new` answers 403 until the pairing window opens, then 200 with `{"auth_token":"…"}` (32 characters). The Nanoleaf app opens the window from the light's advanced settings, **Connect to API**, for 30 seconds. Holding the MAGRGB's power button did not open it in our tests, and holding it for 10 seconds factory-resets the strip. A token the light doesn't know gets 401 on every call.

### Endpoints

All paths are relative to `/api/v1/<token>/`.

| Request | Result |
| --- | --- |
| `GET ` (empty path) | `name`, `serialNo`, `manufacturer`, `firmwareVersion`, `hardwareVersion`, `model`, `state`. No `effects` or `panelLayout`, unlike Nanoleaf panels |
| `GET state` | `on`, `brightness` (1 to 100), `hue` (0 to 360), `sat` (0 to 100), `ct` (2127 to 6535 K), `colorMode` (`hs`, `ct` or `effect`) |
| `GET effects/select` | Current scene name as a JSON string, e.g. `"Northern Lights"` |
| `GET effects/effectsList` | Scene names. Out of the box: Northern Lights, Assassin's Creed, Attack On Titan, Cloud9, Cyberpunk 2077, Dark Knight, Secret Lab Signature, Team Liquid, The Joker, VOLORANT, Volume Up |
| `PUT effects {"write":{"command":"requestAll"}}` | Every scene with `animType: "plugin"`, `pluginType` (`color`, or `rhythm` for Volume Up), `hexPalette` (`["0037FF",…]`) and plugin options |
| `PUT state {"on":{"value":true}}` | 204 |
| `PUT state {"brightness":{"value":64,"duration":0}}` | 204 |
| `PUT state {"hue":{"value":28},"sat":{"value":100}}` | 204, `colorMode` becomes `hs` |
| `PUT state {"ct":{"value":3000}}` | 204, `colorMode` becomes `ct` |
| `PUT effects {"select":"Northern Lights"}` | 204, `colorMode` becomes `effect` |

Not supported on this firmware: `GET effects` and `GET panelLayout` (500), the `events` server-sent event stream (500, so Lights polls every 10 seconds) and `PUT identify` (400).

Values are quantised: white is stored in mireds (3000 K reads back as 3003 K) and hue loses a degree now and then (29 reads back as 28). For colours, Lights keeps the one it sent when the read-back is within that rounding; white shows the value read back.

