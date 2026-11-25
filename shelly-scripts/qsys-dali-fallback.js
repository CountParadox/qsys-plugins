// Q-SYS fallback for DALI wall switches. Runs on the Shelly (Settings > Scripts).
//
// Normally Q-SYS handles the switch: the input is "Detached" and the Shelly plugin
// forwards the presses. Q-SYS also calls this script's "hb" endpoint every 10 s
// (set the plugin's "Fallback Heartbeat Path" to /script/<script id>/hb).
//
// If that heartbeat stops (Core offline, design not running, network to the Core
// down) the switch talks straight to the DALI gateway instead:
//   single press -> toggle the DALI group
//   long press   -> group on at 100 %
//
// Enable "Run on startup" for this script.

let CONFIG = {
  daliHost: "192.168.1.60", // DALI-2 IoT / SmartCore gateway
  daliGroup: 0,             // DALI group (0-15) the switch controls
  probeDevice: 1,           // gateway device id of one fitting in that group (to read on/off)
  input: 0,                 // Shelly input id (0-based)
  heartbeatTimeout: 30,     // seconds without a Q-SYS heartbeat before taking over
  bootGrace: 60,            // seconds after Shelly boot before taking over
};

let lastHeartbeat = 0;
let fallbackActive = false;

function uptime() {
  return Shelly.getComponentStatus("sys").uptime;
}

function qsysAlive() {
  let up = uptime();
  if (lastHeartbeat === 0) return up < CONFIG.bootGrace;
  return up - lastHeartbeat < CONFIG.heartbeatTimeout;
}

function setFallback(active) {
  if (active !== fallbackActive) {
    fallbackActive = active;
    print(active ? "Q-SYS heartbeat lost: switch now controls DALI directly" : "Q-SYS heartbeat restored");
  }
}

HTTPServer.registerEndpoint("hb", function (req, res) {
  lastHeartbeat = uptime();
  setFallback(false);
  res.code = 200;
  res.body = "ok";
  res.send();
});

function daliControl(body) {
  Shelly.call("HTTP.Request", {
    method: "POST",
    url: "http://" + CONFIG.daliHost + "/group/" + JSON.stringify(CONFIG.daliGroup) + "/control",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    timeout: 5,
  }, function (res, errCode, errMsg) {
    if (errCode !== 0) print("DALI command failed: " + errMsg);
  });
}

function daliToggle() {
  Shelly.call("HTTP.GET", {
    url: "http://" + CONFIG.daliHost + "/device/" + JSON.stringify(CONFIG.probeDevice),
    timeout: 3,
  }, function (res, errCode) {
    let on = false;
    if (errCode === 0 && res && res.code === 200) {
      let dev = JSON.parse(res.body);
      if (dev && dev.features && dev.features.switchable) on = dev.features.switchable.status === true;
    }
    // If the state can't be read, switch on: lights on is the safe failure.
    daliControl({ switchable: !on });
  });
}

Shelly.addEventHandler(function (ev) {
  if (!ev || ev.component !== "input:" + JSON.stringify(CONFIG.input)) return;
  if (qsysAlive()) {
    setFallback(false);
    return;
  }
  setFallback(true);
  let e = ev.info ? ev.info.event : "";
  if (e === "single_push" || e === "toggle") daliToggle();
  else if (e === "long_push") daliControl({ dimmable: 100 });
});

print("Q-SYS DALI fallback loaded, group " + JSON.stringify(CONFIG.daliGroup) + " on " + CONFIG.daliHost);
