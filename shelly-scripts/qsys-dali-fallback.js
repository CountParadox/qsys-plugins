// Q-SYS fallback for DALI wall switches on a Shelly input. Runs on the Shelly (Settings > Scripts).
//
// Normally Q-SYS handles the switch: the input is "Detached" and the Shelly plugin
// forwards the presses. Q-SYS also calls this script's "hb" endpoint every 10 s
// (set the Shelly plugin's "Fallback Heartbeat Path" to /script/<script id>/hb).
//
// If that heartbeat stops (Core offline, design not running, network to the Core
// down), the switch talks straight to the Atios SmartCore with raw DALI frames
// (POST /api/dali/iface, the same endpoint the Q-SYS plugin falls back to):
//   single press -> toggle the DALI group (OFF / GO TO LAST ACTIVE LEVEL)
//   long press   -> group to full (RECALL MAX LEVEL)
//
// Enable "Run on startup" for this script. The SmartCore must have no web password.

let CONFIG = {
  smartcore: "192.168.1.60", // Atios SmartCore IP
  daliGroup: 1,              // DALI group (0-15) the switch controls
  probeAddress: 0,           // DALI short address (0-63) of one fitting in that group, to read on/off
  input: 0,                  // Shelly input id (0-based)
  heartbeatTimeout: 30,      // seconds without a Q-SYS heartbeat before taking over
  bootGrace: 60,             // seconds after Shelly boot before taking over
};

let OP_OFF = 0;
let OP_RECALL_MAX = 5;
let OP_GOTO_LAST_ACTIVE = 10;
let OP_QUERY_ACTUAL_LEVEL = 160;

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

// Send one 16-bit DALI frame. cb(answerOrNull) for queries.
function daliFrame(data, waitResponse, cb) {
  Shelly.call("HTTP.Request", {
    method: "POST",
    url: "http://" + CONFIG.smartcore + "/api/dali/iface",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ repeat_twice: false, wait_response: waitResponse, bits: 16, data: data }),
    timeout: 5,
  }, function (res, errCode, errMsg) {
    let answer = null;
    if (errCode !== 0) {
      print("DALI frame failed: " + errMsg);
    } else if (waitResponse && res && res.code === 200) {
      let body = JSON.parse(res.body);
      // Without an answer the SmartCore still reports data 0, so only trust success = true.
      if (body && body.success === true && typeof body.data === "number") answer = body.data;
    }
    if (cb) cb(answer);
  });
}

function groupCommand(op) {
  daliFrame([0x80 | (CONFIG.daliGroup << 1) | 1, op], false, null);
}

function daliToggle() {
  daliFrame([(CONFIG.probeAddress << 1) | 1, OP_QUERY_ACTUAL_LEVEL], true, function (level) {
    // Unknown state: switch on, lights on is the safe failure.
    if (level !== null && level > 0) groupCommand(OP_OFF);
    else groupCommand(OP_GOTO_LAST_ACTIVE);
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
  else if (e === "long_push") groupCommand(OP_RECALL_MAX);
});

print("Q-SYS DALI fallback loaded: group " + JSON.stringify(CONFIG.daliGroup) + " on SmartCore " + CONFIG.smartcore);
