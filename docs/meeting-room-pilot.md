# Meeting room pilot

Goal: the meeting room wall switch controls the meeting room DALI lights through Q-SYS, with a UCI page. The frosting glass Shelly gets a UCI button too. If the Core goes down, the switch still works.

## 0. Before you start
- Give every Shelly and the DALI gateway a **DHCP reservation**. The plugins connect by IP.
- In DALI Cockpit, put the meeting room fittings in a **DALI group** (e.g. group 0) and program the scenes you want (e.g. scene 1 = presentation, scene 2 = video call). Note one fitting's **gateway device id**, which is the `id` in `http://<gateway>/devices`.
- Check the gateway API answers: `http://<gateway>/info` should return JSON with a `version`.

## 1. The wall-switch Shelly
In the Shelly web UI, for the input wired to the meeting room light switch:
- **Input type:** Button (for a momentary retractive switch) or Switch (for a latching switch)
- **Input/output mode:** Detached, so the relay no longer follows the switch and Q-SYS decides
- **Authentication:** off

For a latching switch, Q-SYS gets the input's **State** instead of push events. Tell me if that's the case and I'll adapt the room script.

## 2. Q-SYS design
1. Add **Shelly Gen2+ Device**, name it `Shelly Meeting Room Switch`, and set Switches/Inputs to match the model. Enter the IP.
2. Add another **Shelly Gen2+ Device** for the frosting glass (Shelly 1 Gen3: Switches 1, Inputs 1, Power Metering off). Name it `Shelly Meeting Room Glass`.
3. Add **Lunatone DALI-2 IoT Gateway**, name it `DALI Gateway`, and enter the IP. Set row 1's **DALI Group** to the meeting room group number.
4. On all three components set **Script Access** to `Script`.
5. Add a **Control Script** and paste in `examples/meeting-room.lua`. Edit the config block at the top if the names, input number or scene differ.
6. Deploy. Each plugin's **Status** should go green within a few seconds.

## 3. UCI page
Drag these straight from the plugins onto a UCI:
- DALI `Group 1 ~ On`, `Group 1 ~ Level` (fader), and `Raise` / `Lower`
- Scene buttons: for each scene, a button wired to a **Control Script** or **Snapshot** that sets `Group 1 ~ Scene` and pulses `Recall`. Or wire one button per scene to `Recall` with the scene number fixed.
- Glass Shelly `Switch 1 ~ On` labelled "Privacy glass"
- The plugins' `Online` LEDs on a hidden technician page

## 4. Fallback script (optional but recommended)
1. In the Shelly web UI, go to **Scripts → Create script**, paste `shelly-scripts/qsys-dali-fallback.js`, set `daliHost`, `daliGroup` and `probeDevice`, then save. Turn on **Run on startup** and start the script. Note its id (usually 1).
2. In the Shelly plugin's **Fallback Heartbeat Path**, enter `/script/1/hb`.
3. To test: disable the Control Script, or unplug the Core's LAN. After 30 s a short press on the switch should toggle the lights directly.

## 5. Things to check on the real system
- [ ] Short press toggles, hold dims, double press recalls the scene
- [ ] Fader and UCI follow when the lights are changed elsewhere (DALI Cockpit, broadcast)
- [ ] Unplug the Shelly: Status turns red within about 35 s, then recovers by itself on reconnect
- [ ] Reboot the gateway: Status turns amber while polling, then green
- [ ] Fallback works with the Core offline
