/*
 * Tests the JavaScript that Catalina Player runs inside the Spotify web player,
 * read straight out of Sources/Scripts.swift, against a mock player bar.
 *   npm install && npm test
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { JSDOM } = require("jsdom");

const swift = fs.readFileSync(path.join(__dirname, "..", "Sources", "Scripts.swift"), "utf8");
const [WATCH, NOW, CONTROL] = [...swift.matchAll(/#"""\n([\s\S]*?)\n\s*"""#/g)].map(m => m[1]);

function player(label = "Play") {
  const dom = new JSDOM(`<body>
    <div data-testid="context-item-info-title"><a>Dreams</a></div>
    <div data-testid="context-item-info-artist"><a>Fleetwood Mac</a></div>
    <button data-testid="control-button-skip-back"></button>
    <button data-testid="control-button-playpause" aria-label="${label}"></button>
    <button data-testid="control-button-skip-forward"></button></body>`, { runScripts: "outside-only" });
  const w = dom.window, clicks = [];
  for (const b of w.document.querySelectorAll("button")) b.addEventListener("click", () => clicks.push(b.dataset.testid));
  opened.push(w);
  return { w, clicks, now: () => JSON.parse(w.eval(NOW)), ctl: a => w.eval(CONTROL.replace("\\#(action)", a)) };
}
const opened = [];
test.after(() => { for (const w of opened) w.close(); });   // stops the watcher's timer so the run ends

test("now playing: title, artist and state", () => {
  const p = player("Play");
  assert.deepEqual(p.now(), { title: "Dreams", artist: "Fleetwood Mac", playing: false, docTitle: "" });
  assert.equal(player("Pause").now().playing, true);
});

test("controls press Spotify's own buttons, and play/pause respect the current state", () => {
  const p = player("Play");
  assert.equal(p.ctl("pause"), false);
  assert.equal(p.ctl("play"), true);
  p.ctl("next"); p.ctl("prev"); p.ctl("toggle");
  assert.deepEqual(p.clicks, ["control-button-playpause", "control-button-skip-forward", "control-button-skip-back", "control-button-playpause"]);
  const q = player("Pause");
  assert.equal(q.ctl("play"), false, "already playing: nothing to press");
});

test("falls back to the page title", () => {
  const p = player(); p.w.document.body.innerHTML = ""; p.w.document.title = "Landslide • Fleetwood Mac";
  assert.equal(p.now().docTitle, "Landslide • Fleetwood Mac");
});

test("spots Spotify's playback error and reports it once", async () => {
  const p = player(), msgs = [];
  p.w.webkit = { messageHandlers: { catalina: { postMessage: m => msgs.push(m) } } };
  p.w.eval(WATCH);
  p.w.document.body.innerHTML = "<p>Playback of protected content is not enabled.</p>";
  await new Promise(r => setTimeout(r, 6500));
  assert.equal(msgs.length, 1);
  assert.equal(msgs[0].type, "problem");
});
