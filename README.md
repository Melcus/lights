# Lights

A menu bar app for macOS 26+ that controls office lights: an Elgato Key Light Neo over USB-C, and Govee lamps and Nanoleaf lights (the Secretlab MAGRGB is one) over Wi-Fi. Click the bulb in the menu bar for a Liquid Glass panel, or use global keyboard shortcuts from any app.

## Features

- **Menu bar panel**: each light gets a Control Center-style tile. The orb toggles it, capsule sliders set brightness and colour temperature, and colour lights get colour swatches. Nanoleaf lights also get a Scenes list with the scenes stored on the light, each previewed in its colours (scenes that react to sound are marked with a waveform). Tiles take on the colour each light is emitting.
- **Menu bar icon**: click for the panel, Option-click to toggle every light, right-click for a quick menu. The icon shows whether any light is on.
- **Adaptive lighting** (optional, off by default): like Night Shift for the lights. White lights follow the sun, daylight white while it is up and warming through sunset to a cosy white at night, then back at sunrise. Brightness can follow too (on by default once enabled): 50% of each light's maximum by day and 80% at night, so lights get brighter as it gets dark; flip the values to dim in the evening instead. Turn it on with the sun button in the panel, the menu, a shortcut or Settings > Adaptive, where the day and night values are set and today's curves are shown. Only lights that are on and showing white are adjusted (a light playing a scene is left alone), and lights are never switched on. Changing a light's brightness, colour temperature, colour or scene by hand, in Lights or anywhere else (Control Center, the Govee or Nanoleaf app, the light's own controls), pauses it until the next sunrise or sunset; clicking the "Auto" pill on its tile re-applies adaptive lighting straight away. Sun times come from your time zone's reference city, so no location permission is needed.
- **Global shortcuts** (Settings > Shortcuts): toggle all, all on, all off, brighter, dimmer, toggle any single light, show the panel, toggle adaptive lighting. They use Carbon hot keys, so no Accessibility permission is needed.
- **Settings**: open at login, adaptive lighting, rename lights, see connection details and firmware, pair or forget Nanoleaf lights.
- **Live state**: changes made elsewhere (Elgato Control Center, the Govee or Nanoleaf app, the lights' own buttons) show up within seconds.

## Supported lights

| Light | Connection | Notes |
| --- | --- | --- |
| Elgato Key Light Neo | USB-C | Reverse-engineered HID protocol, see [docs/PROTOCOLS.md](docs/PROTOCOLS.md). Runs alongside Elgato Control Center. |
| Govee lamps (tested: Lyra, H6072) | Wi-Fi | Uses Govee's LAN API. Turn on **LAN Control** for the device in the Govee Home app. |
| Nanoleaf lights (tested: Secretlab MAGRGB XL, NL72S2, firmware 4.0.0) | Wi-Fi | Uses Nanoleaf's local API, found over Bonjour. Pair once: click **Pair** on the light's tile, then in the Nanoleaf app open the light's advanced settings and tap **Connect to API**, which opens a 30-second window (Lights keeps asking for two minutes). The token is kept in your login keychain. |

Other Govee models with LAN Control should work with a generic 2000 K to 9000 K white range. Nanoleaf lights report their own ranges and scenes. Another Elgato USB light needs its product ID added to `ElgatoHID.lightProductIDs`.

## Install

Requires macOS 26 or later and Xcode 26 or later (built with Xcode 27.1).

```sh
make install     # Release build, copy to /Applications, launch
```

The project signs automatically with team `97Q274U3SH`. To build under another Apple account, change `DEVELOPMENT_TEAM` in the target's Signing settings.

Other targets: `make run` (debug build), `make test` (protocol tests), `make snapshots` (renders the panel in every state, light and dark), `make uninstall`, `make clean`.

## Permissions

- **Local Network**: needed for Govee and Nanoleaf lights; macOS asks the first time.
- **Firewall**: Govee replies arrive on UDP port 4002. Validly signed builds are allowed automatically when "Automatically allow downloaded signed software" is on, otherwise allow Lights when macOS asks.
- Nothing else. The Key Light uses plain HID access.

## Troubleshooting

- **Govee lamp missing or "Not responding"**: check LAN Control in the Govee Home app (it can take a few minutes to appear), make sure the Mac and the lamp are on the same network, then use **Search Again** in Settings > Lights. Lights renews its network socket by itself after network changes, sleep, refused sends or a minute of silence, so a lamp that dropped out should come back within seconds.
- **Govee lamp shows "No Local Network access"**: macOS is blocking the app. Turn Lights on in System Settings > Privacy & Security > Local Network. macOS can ask again after each rebuild, because it treats a new build as a new app.
- **Nanoleaf light shows "Not paired"**: it has no token, or rejected the one Lights had (a factory reset wipes them). Pair it again as described above. On the Secretlab MAGRGB, don't use the controller's power button for pairing: holding it for 10 seconds resets the strip and its Wi-Fi.
- **Nanoleaf scene list is out of date**: Lights reloads it every 10 minutes and whenever the light plays a scene it doesn't know.
- **Key Light stops at 40%**: the light reports that its power source can't deliver more. Powering it from a 3 A USB-C supply allows full brightness. The panel marks the unavailable range.
- **A shortcut can't be recorded**: it is already used by macOS or by another action in Lights. Shortcuts need ⌘, ⌥ or ⌃ unless they are function keys.

## Development

```
Lights/              App target (MainActor by default)
  App/               Entry point, menu bar status item, glass panel, debug tools
  Model/             Light, LightStore (optimistic updates, throttling), Throttle
  Devices/           ElgatoUSBService (IOKit HID), GoveeLANService (UDP), NanoleafService (Bonjour, HTTP), Keychain
  Shortcuts/         Shortcut model, Carbon hot keys, persistence
  UI/                Panel views, capsule slider, colours
  Settings/          Settings window and recorder
LightsKit/           Swift package with the protocol code and its tests
docs/PROTOCOLS.md    Device protocols and reverse-engineering notes
```

`LightsKit` holds the wire formats with no UI or I/O, so `make test` runs in seconds. The Elgato fixtures are bytes captured from a real Key Light Neo.

Debug builds also accept scripted commands for end-to-end checks, for example `toggle <light id>`, `scene <light id> <name>`, `dump` or `snapshot <directory>` (renders the live panel off screen), posted as a `ro.tirdea.Lights.debug` distributed notification. See `Lights/App/DebugTools.swift`.
