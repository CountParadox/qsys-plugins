// Runs shelly-scripts/qsys-dali-fallback.js against a mock of the Shelly script runtime.
const fs = require("fs");
const assert = require("assert");
const vm = require("vm");

let up = 0, handler = null, endpoint = null, calls = [], level = 0, answerOk = true;
const ctx = {
  print: () => {},
  JSON,
  Shelly: {
    getComponentStatus: () => ({ uptime: up }),
    addEventHandler: (fn) => { handler = fn; },
    call: (method, params, cb) => {
      const body = JSON.parse(params.body);
      calls.push({ method, url: params.url, body });
      if (body.wait_response) cb({ code: 200, body: JSON.stringify({ success: answerOk, data: answerOk ? level : 0 }) }, 0, "");
      else cb({ code: 200, body: "{}" }, 0, "");
    },
  },
  HTTPServer: { registerEndpoint: (name, fn) => { assert.strictEqual(name, "hb"); endpoint = fn; } },
};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync("shelly-scripts/qsys-dali-fallback.js", "utf8"), ctx);

const press = (event, component = "input:0") => handler({ component, info: { event } });
const hb = () => endpoint({}, { send() {} });
const commands = () => calls.filter((c) => !c.body.wait_response);
const last = () => commands()[commands().length - 1].body.data;
let n = 0;
const ok = (c, m) => { assert(c, m); n++; };

up = 10; press("single_push");
ok(calls.length === 0, "boot grace: Q-SYS assumed alive");

up = 100; hb(); up = 110; press("single_push");
ok(calls.length === 0, "heartbeat fresh: nothing sent");

up = 200; level = 0; press("single_push");
ok(calls[0].url === "http://192.168.1.60/api/dali/iface" && calls[0].body.wait_response === true
  && calls[0].body.data[0] === 0x01 && calls[0].body.data[1] === 0xA0, "queries actual level of the probe fitting");
ok(commands().length === 1 && last()[0] === 0x83 && last()[1] === 0x0A, "off -> GO TO LAST ACTIVE LEVEL to group 1");

level = 200; press("single_push");
ok(last()[0] === 0x83 && last()[1] === 0x00, "on -> OFF");

answerOk = false; press("single_push");
ok(last()[1] === 0x0A, "no answer -> switch on");

press("long_push");
ok(last()[1] === 0x05, "long press -> RECALL MAX");

const before = calls.length;
press("single_push", "input:1");
ok(calls.length === before, "other inputs ignored");

hb(); press("single_push");
ok(calls.length === before, "heartbeat restored: back to Q-SYS");

console.log(`fallback: ${n} checks passed`);
