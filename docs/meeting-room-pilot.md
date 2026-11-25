# Meeting room pilot

Goal: the meeting room wall switch controls the meeting room DALI lights through Q-SYS, with a UCI page. The frosting glass Shelly gets a UCI button too. If the Core goes down, the switch still works.

## 0. Before you start
- Give every Shelly and the SmartCore a **DHCP reservation**. The plugins connect by IP.
- In the SmartCore web UI (find it via setup.atios.ch):
  - In the **DALI Configurator**, put the meeting room fittings in a **DALI group** and give the group a name (it shows up in Q-SYS). Program the scenes you want, e.g. scene 1 = presentation and scene 2 = video call. Note one fitting's **short address**; the fallback script needs it.
  - Under **System → DALI**, turn on **DALI IP Interface**.
  - Make sure the SmartCore has **no web password**. Without that, the built-in inputs and the Shelly fallback won't work.
  - Check that no other DALI IP client is connected: Home Assistant's Atios integration (Matter is fine), DALI Cockpit, or a monitor script.
- Quick checks from a PC on that network:
  - `http://<smartcore>/ota_status` should show the firmware version. Avoid 3.2.2.
  - `http://<smartcore>/settings` should show `"dali_ip_interface": true`.
  - `http://<smartcore>/api/dali/nvm?section=control_devices&offset=0&limit=4` should list your fittings and groups.

## 1. The wall-switch Shelly
In the Shelly web UI, for the input wired to the meeting room light switch:
- **Input type:** Button (for a momentary retractive switch) or Switch (for a latching switch)
- **Input/output mode:** Detached, so the relay no longer follows the switch and Q-SYS decides
- **Authentication:** off

For a latching switch, Q-SYS gets the input's **State** instead of push events. Tell me if that's the case and I'll adapt the room script.

## 2. Q-SYS design
1. Add **Shelly Gen2+ Device**, name it `Shelly Meeting Room Switch`, and set Switches/Inputs to match the model. Enter the IP.
2. Add another **Shelly Gen2+ Device** for the frosting glass (Shelly 1 Gen3: Switches 1, Inputs 1, Power Metering off). Name it `Shelly Meeting Room Glass`.
3. Add **Atios SmartCore DALI** and name it `SmartCore DALI`. Turn Tunable White on if the fittings are DT8. Enter the IP, and set row 1's **DALI Group** to the meeting room group number. The row's name should then show the group name from the SmartCore.
4. On all three components set **Script Access** to `Script`.
5. Add a **Control Script** and paste in `examples/meeting-room.lua`. Edit the config block at the top if the names, input number or scene differ.
6. Deploy. Each plugin's **Status** should go green within a few seconds. On the SmartCore plugin, **Live Feedback** should be lit.

## 3. UCI page
Drag these straight from the plugins onto a UCI:
- SmartCore `Group 1 ~ On`, `Group 1 ~ Level` (fader), and `Raise` / `Lower`
- Scene buttons: for each scene, a button wired to a **Control Script** or **Snapshot** that sets `Group 1 ~ Scene` and pulses `Recall`
- Glass Shelly `Switch 1 ~ On` labelled "Privacy glass"
- The plugins' `Online` / `Live Feedback` LEDs on a hidden technician page

## 4. Fallback when Q-SYS is down
Two options. Ideally use both.

**a) Shelly script.** The switch talks to the SmartCore directly.
1. In the Shelly web UI, go to **Scripts → Create script** and paste `shelly-scripts/qsys-dali-fallback.js`. Set `smartcore`, `daliGroup` and `probeAddress` (the short address of one fitting in the group), then save. Turn on **Run on startup** and start the script. Note its id (usually 1).
2. In the Shelly plugin's **Fallback Heartbeat Path**, enter `/script/1/hb`.
3. To test: disable the Control Script, or unplug the Core's LAN. After 30 s a short press should toggle the lights.

**b) Local switches on the SmartCore (most robust).** Wire key switches to the SmartCore's built-in inputs, or use DALI-2 push-button couplers, and bind them to the group in the SmartCore's **Accessory Manager**. These keep working with no network at all. Q-SYS still sees every resulting DALI frame, so the UCI stays in sync, and the inputs show up on the plugin's **Built-in Input** LEDs.

## 5. Things to check on the real system
- [ ] Group name, fitting count and current level are correct after deploying
- [ ] Short press toggles, hold dims smoothly (DALI UP/DOWN), double press recalls the scene
- [ ] Changing the lights from the SmartCore web UI or an accessory moves the Q-SYS fader within about a second
- [ ] Colour temperature fader works (DT8 fittings only)
- [ ] Unplug the SmartCore: Status turns red after three failed requests, then recovers by itself
- [ ] Turn DALI IP Interface off: Status turns amber with the message, and control still works
- [ ] Shelly fallback works with the Core offline
