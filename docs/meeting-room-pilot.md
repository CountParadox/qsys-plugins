# Meeting room pilot

Goal: the meeting room (boardroom) DALI lights, frosting glass and presence sensor are on the Q-SYS Core with a UCI page, running alongside Home Assistant until the pilot is signed off.

## Site facts (checked 2026-11-25)

| Device | IP | Notes |
|---|---|---|
| Q-SYS Core 510i `PARTISAN-QSYSC1` | 192.168.60.11 | Firmware **10.5.0**. Already running the design **"Partisan - MiniScreen Projector"** |
| Atios SmartCore (DALI) | 192.168.60.14 | DALI-2 IoT WebSocket protocol 3.0, fw 3.2.64-beta. **No REST API.** One DALI line, 23 fittings, all DT6 D4i LED drivers (no DT8, no relays) |
| Frosting glass, Shelly 1 Gen3 | 192.168.60.224 | Switch 0 "Frosting". Input = Button, relay mode = Momentary (the room's own button drives the glass directly) |
| Presence Gen4 | 192.168.61.207 | Zone `presencezone:200` "Room" is the main zone. Illuminance reports dark / twilight / bright (no lux) |

DALI groups on the bus (from the plugin's scan):

| Group | Short addresses | Fittings |
|---|---|---|
| 2 | 0, 1, 2, 4, 7, 14, 15 | 7 |
| 3 | 3, 6, 8, 9, 13, 17, 23 | 7 |
| **4 (meeting room, to confirm)** | 26, 27, 28 | 3 |
| 5 | 18, 19, 20, 21, 22, 24 | 6 |

The meeting room has no Shelly wall switch, so `examples/meeting-room.lua` and the Shelly fallback script are **not** part of this pilot (see the end of this document).

## 0. Before you start
- [ ] **Designer 10.5** on the PC that will deploy. Designer must match the Core's firmware (10.5). Do not deploy from 10.4 or older: Designer will offer to change the Core's firmware.
- [ ] Give the SmartCore, the glass Shelly and the Presence sensor **DHCP reservations**. The plugins connect by IP.
- [ ] Confirm group 4 is the meeting room. Running group 4 to 50% and back should change only the meeting room lights; it was tested this way on 2026-11-25.
- [ ] Decide how to add the pilot to the Core. It is running "Partisan - MiniScreen Projector", and a deploy replaces whatever is running. **Add the pilot components to that design** (File > Load from Core, or the saved .qsys), save it as a new revision, and keep the previous file to roll back to.

## 1. Install the plugins
Copy `plugins/Shelly-Gen2.qplug` and `plugins/Lunatone-DALI2-IoT.qplug` to `Documents\QSC\Q-Sys Designer\Plugins` and restart Designer. They appear under **Plugins** in the Schematic Library.

## 2. Try it in Emulate first
Designer's Emulate mode runs plugin Lua on the PC, so the plugins can talk to the real devices without touching the Core.
1. In a new, empty design, add the three components from step 3.
2. Press **F6** (Emulate) and check each plugin's Status goes green.
3. Check the controls follow the devices, as in step 5.

## 3. Components
Add these to the design:

| Component | Name | Properties | Setup |
|---|---|---|---|
| Lunatone DALI-2 IoT Gateway | `DALI Gateway` | Rows 1, Colour Control None | IP 192.168.60.14, row 1 **Address** = `G4` |
| Shelly Gen2+ Device | `Shelly Meeting Room Glass` | Switches 1, Inputs 1, Lights 0, Covers 0, Power Metering off | IP 192.168.60.224 |
| Shelly Gen2+ Device | `Meeting Room Presence` | Switches 0, Inputs 0, Power Metering off, Presence Zones 1, Illuminance on | IP 192.168.61.207 |

Set **Script Access** to `Script` on all three if you plan to add room logic later.

Deploy (F5) to the Core. Each Status should go green. The DALI gateway shows "Scanning DALI bus" for about 25 seconds after connecting, then **Fittings = 23**, and row 1 shows **3** fittings of type `3x DT6`.

## 4. UCI page
- DALI row 1: `Group 1 ~ On`, `Group 1 ~ Level` (fader), `Raise` / `Lower`, `Scene` + `Recall Scene` (if scenes are programmed for group 4)
- Glass: `Switch 1 ~ On`, labelled "Privacy glass"
- Presence: `Presence ~ Zone 1 Occupied` (LED) and `Presence ~ Illuminance`
- Technician page: each plugin's `Online` LED and Status, and the DALI row's `Fault` LED and `Fault Detail`

## 5. Things to check on the real system
- [ ] UCI On / Off / fader / Raise / Lower change only the meeting room lights
- [ ] Lights changed from Home Assistant or DALI Cockpit show on the UCI within about 5 s (the plugin polls; the gateway does not push changes made by other clients)
- [ ] Glass: the UCI button toggles the glass, and pressing the room's own button updates the UCI immediately
- [ ] Presence: Occupied turns on within a few seconds of someone entering, and off after they leave
- [ ] Unplug the glass Shelly: Status turns red within about 35 s, then recovers by itself
- [ ] Reboot the SmartCore: DALI Status turns red ("reconnecting"), then green after it rescans
- [ ] Home Assistant and Q-SYS both controlling the lights doesn't cause problems (no fighting)

## Rooms with a Shelly wall switch (not this room)
`examples/meeting-room.lua` links a Shelly input to a DALI group: short press toggles, hold dims, double press recalls a scene. It expects the input set to **Button** and the relay **Detached**. For a latching switch (input type **Switch**), the Shelly sends input state changes instead of push events and the script needs adapting.

`shelly-scripts/qsys-dali-fallback.js` needs a gateway with the DALI-2 IoT REST API. The SmartCore doesn't have one, so the fallback can't be used with it as it stands.
