# Q-SYS building control plugins

Q-SYS plugins and scripts that move building control (Shelly relays and switches, DALI lighting) off Home Assistant and onto the Q-SYS Core.

| Path | What it is |
|---|---|
| `plugins/Shelly-Gen2.qplug` | Shelly Gen2/Gen3/Gen4/Pro device: switches, inputs (push, double, triple, long, hold), dimmer channels, covers, power and energy |
| `plugins/Lunatone-DALI2-IoT.qplug` | Lunatone DALI-2 IoT gateway (and devices with the same API, e.g. the SmartCore in DALI-2 IoT mode): group on/off, level, raise/lower, scenes, colour temperature, broadcast |
| `examples/meeting-room.lua` | Room logic linking a Shelly wall switch to a DALI group (press = toggle, hold = dim, double = scene) |
| `shelly-scripts/qsys-dali-fallback.js` | Runs on the Shelly: if Q-SYS stops sending heartbeats, the switch controls DALI directly |
| `docs/meeting-room-pilot.md` | Step-by-step pilot setup |
| `tests/` | Offline tests against a mock Q-SYS runtime (`tests/run.sh`) |

## How it works

```
Wall switch ─► Shelly input (Detached) ══ WebSocket ws://shelly/rpc ══╗
                                                                     ║
UCI touch panels ◄──────────────────────────────────────────►  Q-SYS Core (logic)
                                                                     ║
DALI fittings ◄── DALI bus ◄── DALI-2 IoT gateway ◄═ REST + WebSocket╝
```

- **Shelly:** the plugin keeps one WebSocket open to each Shelly. The Shelly pushes status changes and button events down it immediately. Every 10 s the plugin re-reads the full status and drops and reopens the connection if the device has gone quiet for 35 s. If the WebSocket is down, commands are sent over HTTP instead. Nothing needs configuring on the Shelly except the input mode.
- **DALI:** commands go to `POST /group/{n}/control`. The gateway's WebSocket pushes fitting changes, and the plugin works out each group's state from its fittings (on if any fitting is on, level = the highest). If the WebSocket is down, it polls `GET /devices` every 10 s.
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
| Power Metering | Expose W and kWh per switch |

Shelly authentication must be **off**. Keep these devices on a controlled VLAN instead.

### DALI-2 IoT properties
| Property | Use |
|---|---|
| Group Rows | How many group rows to show. Each row has a **DALI Group** number (0-15) set on the plugin |
| Tunable White | Adds a colour-temperature fader per row |
| Port | Gateway HTTP port (80) |

## Status and limits
- Version 0.1.0 has been tested offline against a mock Q-SYS runtime, but not yet on a Core. The first run on the Core is the meeting-room pilot.
- Not yet supported: Shelly authentication, RGBW colour mode, Presence Gen4 (its API still needs mapping), Pro 3EM / Pro EM-50 meters, and DALI zones.

## Tests
```
sudo apt-get install lua5.3 lua-cjson   # plus node for the Shelly script test
./tests/run.sh
```
