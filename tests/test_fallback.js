// Runs shelly-scripts/qsys-dali-fallback.js against a mock of the Shelly script runtime.
const fs = require("fs");
const assert = require("assert");
const vm = require("vm");

let up = 0, handler = null, endpoint = null, calls = [], deviceOn = false;
const ctx = {
  print: () => {},
  JSON,
  Shelly: {
    getComponentStatus: () => ({ uptime: up }),
    addEventHandler: (fn) => { handler = fn; },
    call: (method, params, cb) => {
      calls.push({ method, params });
      if (method === "HTTP.GET") cb({ code: 200, body: JSON.stringify({ id: 1, features: { switchable: { status: deviceOn } } }) }, 0, "");
      else cb({ code: 200 }, 0, "");
    },
  },
  HTTPServer: { registerEndpoint: (name, fn) => { assert.strictEqual(name, "hb"); endpoint = fn; } },
};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync("shelly-scripts/qsys-dali-fallback.js", "utf8"), ctx);

const press = (event, component = "input:0") => handler({ component, info: { event } });
const hb = () => endpoint({}, { send() {} });
const posts = () => calls.filter((c) => c.method === "HTTP.Request");
let n = 0;
const ok = (c, m) => { assert(c, m); n++; };

up = 10; press("single_push");
ok(posts().length === 0, "boot grace: Q-SYS assumed alive");

up = 100; hb(); up = 110; press("single_push");
ok(posts().length === 0, "heartbeat fresh: nothing sent");

up = 200; deviceOn = false; press("single_push");
ok(posts().length === 1, "heartbeat stale: fallback sends");
const p = posts()[0].params;
ok(p.url === "http://192.168.1.60/group/0/control" && JSON.parse(p.body).switchable === true, "toggles off->on");

deviceOn = true; press("single_push");
ok(JSON.parse(posts()[1].params.body).switchable === false, "toggles on->off");

press("long_push");
ok(JSON.parse(posts()[2].params.body).dimmable === 100, "long press -> 100%");

press("single_push", "input:1");
ok(posts().length === 3, "other inputs ignored");

hb(); press("single_push");
ok(posts().length === 3, "heartbeat restored: back to Q-SYS");

console.log(`fallback: ${n} checks passed`);
