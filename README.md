# Q-SYS building control plugins

Q-SYS plugins and scripts that move building control (Shelly relays and switches, DALI lighting) off Home Assistant and onto the Q-SYS Core.

| Path | What it is |
|---|---|
| `plugins/Shelly-Gen2.qplug` | Shelly Gen2/Gen3/Gen4/Pro device: switches, inputs (push, double, triple, long, hold), dimmer channels, covers, power and energy, Presence Gen4 occupancy and illuminance |
| `plugins/Lunatone-DALI2-IoT.qplug` | Lunatone DALI-2 IoT gateway, or anything speaking its WebSocket protocol (e.g. the Atios SmartCore): DT6 LED, DT7 relays and DT8 colour (Tc, RGBW) by group, single fitting or broadcast; scenes; fault reporting |
| `examples/meeting-room.lua` | Room logic linking a Shelly wall switch to a DALI group (press = toggle, hold = dim, double = scene) |
| `shelly-scripts/qsys-dali-fallback.js` | Runs on the Shelly: if Q-SYS stops sending heartbeats, the switch controls DALI directly. Needs a gateway with the REST API, so **not usable with the SmartCore** |
| `docs/meeting-room-pilot.md` | Step-by-step pilot setup |
| `tests/` | Offline tests against a mock Q-SYS runtime (`tests/run.sh`) |

## How it works

```
Wall switch ─► Shelly input (Detached) ══ WebSocket ws://shelly/rpc ══╗
                                                                     ║
UCI touch panels ◄──────────────────────────────────────────►  Q-SYS Core (logic)
                                                                     ║
DALI fittings ◄── DALI bus ◄── DALI-2 IoT gateway ◄══ WebSocket ═════╝
```

- **Shelly:** the plugin keeps one WebSocket open to each Shelly. The Shelly pushes status changes and button events down it immediately. Every 10 s the plugin re-reads the full status and drops and reopens the connection if the device has gone quiet for 35 s. If the WebSocket is down, commands are sent over HTTP instead. Nothing needs configuring on the Shelly except the input mode.
- **DALI:** the plugin sends raw DALI frames over the gateway WebSocket (`ws://<gateway>/`, `daliFrame` messages): DAPC for levels, OFF, GO TO SCENE, and DT8 Tc for colour temperature, addressed to the group. On connect it scans short addresses 0-63 and reads each fitting's groups. It then reads back the level of every fitting in the configured groups every 5 s, plus 0.4 s and 2.5 s after each command. Group state is derived from the fittings (on if any is on, level = the highest). Polling is needed because the gateway only reports a client's own traffic: changes made from DALI Cockpit or Home Assistant are never pushed. The SmartCore has no REST API (`/info`, `/devices` and `/group/{n}/control` return 404).
- **Presence Gen4:** occupancy is in dynamic `presencezone:<id>` components that `Shelly.GetStatus` omits, so the plugin reads them with `Shelly.GetComponents` on connect and every 10 s, and also applies NotifyStatus updates.
- **Addressing, groups and scenes** are set up in DALI Cockpit or the gateway's web UI. Q-SYS only calls groups and scenes.

## Installing the plugins

Copy the `.qplug` files to `Documents\QSC\Q-Sys Designer\Plugins` and restart Designer. They appear under **Plugins** in the Schematic Library. Requires Designer 9.8 or newer, for Lua WebSocket support. Developed for 10.5 on a Core 510i.

### Shelly Gen2+ properties
| Property | Use |
|---|---|
| Switches | Relay channels (1PM = 1, 2PM = 2, Pro 4PM = 4) |
| Inputs | SW inputs to expose (1 or 2 on 1PM/2PM, 4 on Pro 4PM/i4) |
| Lights | Dimmer channels (Plus RGBW PM in light mode, Dimmer 2) |
| Covers | Set to 1 for a 2PM in cover mode (e.g. the projector screen) |
| Presence Zones | Presence Gen4: zones to expose (Occupied, People, Name). Zone 1 is the sensor's main zone |
| Illuminance | Presence Gen4: illuminance text (dark / twilight / bright, plus lux if the firmware reports it) |
| Power Metering | Expose W and kWh per switch |

Shelly authentication must be **off**. Keep these devices on a controlled VLAN instead.

### DALI-2 IoT properties
| Property | Use |
|---|---|
| Rows | How many control rows to show. Each row's **Address** is set on the plugin: `G0`-`G15` (or just `0`-`15`) for a group, `A0`-`A63` for one fitting (e.g. a relay), `BC` for broadcast |
| Colour Control | None, Tunable White (Kelvin fader per row), RGBW (R, G, B, W faders per row), or both |
| Kelvin Min / Max | Range of the Kelvin faders (default 2700-6500 K) |
| Port | Gateway WebSocket port (80) |

### Device types
| DALI device type | Support |
|---|---|
| DT6 LED (incl. D4i) | On/off, level, raise/lower, scenes, lamp/gear failure. Tested on site (23 D4i drivers) |
| DT7 relay / switching | On/off (DAPC 254 / OFF), state from the actual level. Offline tests only: no relays on site |
| DT8 colour, Tc | Colour temperature (SET TEMPORARY COLOUR TEMPERATURE + ACTIVATE) with read-back via QUERY COLOUR VALUE. Offline tests only |
| DT8 colour, RGB/RGBW | R, G, B, W levels (SET TEMPORARY RGB / WAF DIMLEVEL + ACTIVATE) with read-back. Offline tests only |
| Other types | On/off, level and scenes (IEC 62386-102 commands) |

Each row shows its fittings' **Types** (e.g. `3x DT6`, `1x Relay`, `2x DT8 Tc`) and a **Fault** LED with detail (lamp failure, gear failure, or a fitting that has stopped answering). The bus scan on connect reads every fitting's groups, device types (including multi-type DALI-2 gear) and DT8 colour features; on site it takes about 25 s. Commands still go out during a scan. Failure status is re-read every 60 s, colour every 30 s.

## Status and limits
- Shelly plugin 0.2.0 and DALI plugin 0.3.0 have been run against the real devices from a PC (`tests/live/bridge.py`, below): SmartCore scan (23 fittings, groups 2-5), group 4 level and readback, Presence Gen4 zone and illuminance, Shelly 1 Gen3 status. Not yet run on the Core.
- DT7 relays and DT8 colour are implemented to IEC 62386-208/-209 and tested against a simulated bus only: every fitting on site is DT6. Test them on real gear before relying on them.
- Not yet supported: Shelly authentication, RGBW colour mode, Pro 3EM / Pro EM-50 meters, and DALI zones.

## Tests
```
./tests/run.sh
```
Needs Lua 5.3 (the Q-SYS Lua version) and node. On Windows: `scoop bucket add versions; scoop install versions/lua53`. lua-cjson is used if installed, otherwise the pure-Lua `tests/json.lua`.

### Against real devices, without a Core
`tests/live/bridge.py` runs a plugin on the offline mock runtime and relays its WebSocket traffic to a real device (Python 3 standard library only). Examples:
```
python tests/live/bridge.py 40 plugins/Lunatone-DALI2-IoT.qplug 192.168.60.14 Rows=1 @Group1Address=G4
python tests/live/bridge.py 15 plugins/Shelly-Gen2.qplug 192.168.61.207 Switches=0 Inputs=0 "Presence Zones=1" Illuminance=true
```
`Prop=value` sets a property, `@Control=value` sets a control before start, `--at SECONDS "SET Control Field Value"` / `--at SECONDS "PRESS Control"` acts while running, and `--log` prints every frame. The controls are printed at the end. Only add `--at` actions you mean to send to the real device.
