# Q-SYS building control plugins

Q-SYS plugins and scripts that move building control (Shelly relays and switches, DALI lighting) off Home Assistant and onto the Q-SYS Core.

| Path | What it is |
|---|---|
| `plugins/Shelly-Gen2.qplug` | Shelly Gen2/Gen3/Gen4/Pro device: switches, inputs (push, double, triple, long, hold), dimmer channels, covers, power and energy |
| `plugins/Atios-SmartCore-DALI.qplug` | Atios SmartCore: DALI group on/off, level, raise/lower, scenes, colour temperature (DT8), broadcast, built-in inputs 1-12, bus-scan detection |
| `examples/meeting-room.lua` | Room logic linking a Shelly wall switch to a DALI group (press = toggle, hold = dim, double = scene) |
| `shelly-scripts/qsys-dali-fallback.js` | Runs on the Shelly: if Q-SYS stops sending heartbeats, the switch controls DALI on the SmartCore directly |
| `docs/meeting-room-pilot.md` | Step-by-step pilot setup |
| `tests/` | Offline tests against a mock Q-SYS runtime and a fake SmartCore (`tests/run.sh`) |

## How it works

```
Wall switch ─► Shelly input (Detached) ══ WebSocket ws://shelly/rpc ══╗
                                                                     ║
UCI touch panels ◄──────────────────────────────────────────►  Q-SYS Core (logic)
                                                                     ║
DALI fittings ◄── DALI bus ◄── Atios SmartCore ◄═ ws://sc/ + HTTP ═══╝
```

### Shelly
The plugin keeps one WebSocket open to each Shelly. The Shelly pushes status changes and button events down it immediately. Every 10 s the plugin re-reads the full status, and it reconnects if the device has been silent for 35 s. If the WebSocket is down, commands are sent over HTTP instead. Nothing needs configuring on the Shelly except the input mode.

### Atios SmartCore
The plugin uses the same interface as Atios's own [Home Assistant integration](https://github.com/Atios-AG/homeassistant-smartcore):

- **Commands** are raw DALI-2 frames: arc power for levels, plus OFF, GO TO LAST ACTIVE LEVEL, UP/DOWN, GO TO SCENE and the DT8 colour-temperature commands. They are sent as `daliFrame` on the DALI IP Interface socket `ws://<ip>/`, or as `POST /api/dali/iface` when the socket is down.
- **Feedback.** The SmartCore echoes every frame on the bus as `daliMonitor`. That includes our own frames, the SmartCore's own accessories and other masters. The plugin applies each frame to a mirror of every fitting's level, using the same rules as the SmartCore firmware. Levels are read with QUERY ACTUAL LEVEL at start-up, after a reconnect, and after commands whose result the frame alone doesn't tell (a scene without a stored level, for example). A group's level is the highest level among its fittings.
- **Names, groups and scenes** come from the SmartCore's device model (`GET /api/dali/nvm`), so they match what you set up in its DALI Configurator.
- **Built-in inputs 1-12** come from `ws://<ip>/ws`, with a lease renewed every 10 s. This needs firmware 3.2.64 or newer and **no web password**.
- **Bus scans.** While a scan is running, the SmartCore holds DALI-2 devices in quiescent mode. The plugin detects this, lights **Bus Scan** and pauses its commands.

#### SmartCore requirements
- **System → DALI → DALI IP Interface: ON.** Without it, control still works but there is no live feedback, so the plugin polls levels every 30 s. Status shows amber and says so.
- **Q-SYS must be the only DALI IP Interface client.** The socket serves one client, and the newest connection takes it over. Don't run Home Assistant's Atios integration, DALI Cockpit, `tools/monitor.py`, or a second copy of this plugin against the same SmartCore. If something does take the socket over, the plugin notices within 15 s and reconnects. That kicks the other client off again, so the two will keep taking the socket from each other.
- **Avoid firmware 3.2.2.** On that version the socket never streams; Status reports "firmware sends no DALI IP events".

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

### Atios SmartCore DALI properties
| Property | Use |
|---|---|
| Group Rows | How many group rows to show. Each row has a **DALI Group** number (0-15). The name is read from the SmartCore |
| Tunable White | Adds a colour-temperature fader per row (DT8 Tc) |
| Built-in Inputs | Adds LEDs for SmartCore inputs 1-12 |

Status colours: green means live; amber means it's working but something is degraded (the message says what); red means the SmartCore isn't responding.

## Status and limits
- Version 0.2.0 has been tested offline only, against a mock Q-SYS runtime and a fake SmartCore. The first run on the Core is the meeting-room pilot.
- **Not yet supported:**
  - Shelly authentication
  - RGBW colour mode
  - Presence Gen4 (its API still needs mapping)
  - Pro 3EM / Pro EM-50 meters
  - DALI single-address rows
  - Named DALI-2 push-button events (the **Last Bus Event** field shows raw events for commissioning)

## Tests
```
sudo apt-get install lua5.3 lua-cjson   # plus node for the Shelly script test
./tests/run.sh
```
