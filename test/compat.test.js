/*
 * Tests the compatibility shim (Sources/Compat.swift) and the diagnostic probes
 * (Sources/Diagnostics.swift). Native implementations are deleted first, so each polyfill
 * is actually exercised, then compared with what the native version (Node 20+) returns.
 *   npm test
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { JSDOM } = require("jsdom");

const read = f => fs.readFileSync(path.join(__dirname, "..", "Sources", f), "utf8");
const blocks = src => [...src.matchAll(/#"""\n([\s\S]*?)\n\s*"""#/g)].map(m => m[1]);
const [SHIM] = blocks(read("Compat.swift"));
const [ERRORS, FEATURES, RENDER] = blocks(read("Diagnostics.swift"));

// A fresh JS realm with the modern functions removed, as on Safari 15.6.
function oldEngine() {
  const posted = [];
  const ctx = vm.createContext({ setTimeout, clearTimeout, console, posted,
    window: {}, location: { host: "open.spotify.com", pathname: "/" } });
  vm.runInContext(`
    delete Array.prototype.toSorted; delete Array.prototype.toReversed; delete Array.prototype.toSpliced;
    delete Array.prototype.with; delete Array.prototype.findLast; delete Array.prototype.findLastIndex;
    delete Object.groupBy; delete Map.groupBy; delete Promise.withResolvers; delete Array.fromAsync;
    delete String.prototype.isWellFormed; delete String.prototype.toWellFormed;
    for (const m of ['union','intersection','difference','symmetricDifference','isSubsetOf','isSupersetOf','isDisjointFrom']) delete Set.prototype[m];
    window.webkit = { messageHandlers: { catalina: { postMessage: o => posted.push(o) } } };
  `, ctx);
  vm.runInContext(SHIM.replace(/window\.__catalinaCompat/g, "this.__catalinaCompat"), ctx);
  return { ctx, posted, run: code => vm.runInContext(code, ctx) };
}

test("shim fills every gap it claims to and reports them", () => {
  const e = oldEngine();
  assert.equal(e.posted.length, 1);
  assert.equal(e.posted[0].type, "compat");
  for (const name of ["Array.toSorted", "Array.with", "Object.groupBy", "Map.groupBy", "Promise.withResolvers",
                      "Array.fromAsync", "String.isWellFormed", "Set.union", "Set.isDisjointFrom"]) {
    assert.ok(e.posted[0].added.includes(name), name);
  }
});

test("array copies behave like the native ones", () => {
  const { run } = oldEngine();
  assert.deepEqual(run("JSON.stringify([3,1,2].toSorted())"), JSON.stringify([3, 1, 2].toSorted()));
  assert.deepEqual(run("JSON.stringify([3,1,2].toSorted((a,b)=>b-a))"), "[3,2,1]");
  assert.equal(run("var a=[1,2,3]; a.toReversed(); a.join()"), "1,2,3");
  assert.equal(run("[1,2,3].toReversed().join()"), "3,2,1");
  assert.equal(run("[1,2,3,4].toSpliced(1,2,'x').join()"), [1, 2, 3, 4].toSpliced(1, 2, "x").join());
  assert.equal(run("[1,2,3].toSpliced().join()"), "1,2,3");
  assert.equal(run("[1,2,3].with(-1,9).join()"), "1,2,9");
  assert.throws(() => run("[1,2,3].with(5,0)"), /Invalid index/);
  assert.equal(run("[1,2,3,4].findLast(x=>x%2)"), 3);
  assert.equal(run("[1,2,3,4].findLastIndex(x=>x>9)"), -1);
});

test("groupBy, withResolvers and fromAsync", async () => {
  const { run } = oldEngine();
  assert.equal(run("JSON.stringify(Object.groupBy([1,2,3,4], x => x % 2 ? 'odd' : 'even'))"),
               JSON.stringify(Object.groupBy([1, 2, 3, 4], x => x % 2 ? "odd" : "even")));
  assert.equal(run("Object.getPrototypeOf(Object.groupBy([], x => x))"), null);
  assert.equal(run("Map.groupBy([1,2,3], x => x > 1).get(true).join()"), "2,3");
  assert.equal(await run("(() => { const r = Promise.withResolvers(); setTimeout(() => r.resolve(7)); return r.promise; })()"), 7);
  assert.deepEqual(JSON.stringify(await run("Array.fromAsync([Promise.resolve(1), 2], x => x * 10)")), "[10,20]");
  assert.deepEqual(JSON.stringify(await run("Array.fromAsync((async function*(){ yield 1; yield 2; })())")), "[1,2]");
});

test("well-formed strings", () => {
  const { run } = oldEngine();
  for (const s of ["abc", "a\uD800", "\uDC00b", "😀", "x\uD800y\uDC00"]) {
    const lit = JSON.stringify(s);
    assert.equal(run(`${lit}.isWellFormed()`), s.isWellFormed(), lit);
    assert.equal(run(`${lit}.toWellFormed()`), s.toWellFormed(), lit);
  }
});

test("Set methods match the native ones", () => {
  const { run } = oldEngine();
  const cases = {
    union: [1, 2, 3, 4], intersection: [2, 3], difference: [1], symmetricDifference: [1, 4],
  };
  for (const [m, want] of Object.entries(cases)) {
    assert.equal(run(`JSON.stringify([...new Set([1,2,3]).${m}(new Set([2,3,4]))].sort())`), JSON.stringify(want), m);
  }
  assert.equal(run("new Set([1]).isSubsetOf(new Set([1,2]))"), true);
  assert.equal(run("new Set([1,2]).isSupersetOf(new Set([2]))"), true);
  assert.equal(run("new Set([1]).isDisjointFrom(new Set([2]))"), true);
  assert.throws(() => run("new Set([1]).union([1])"), /set-like/);
});

test("shim never replaces a native function", () => {
  const ctx = vm.createContext({ window: {}, location: { host: "", pathname: "" } });
  const native = vm.runInContext("Array.prototype.toSorted", ctx);
  vm.runInContext(SHIM.replace(/window\.__catalinaCompat/g, "this.__catalinaCompat"), ctx);
  assert.equal(vm.runInContext("Array.prototype.toSorted", ctx), native);
  assert.deepEqual([...vm.runInContext("this.__catalinaCompat", ctx)], []);
});

test("shim source itself uses no syntax Safari 15.6 lacks", () => {
  assert.doesNotMatch(SHIM, /\(\?<[=!]/, "regex lookbehind");
  assert.doesNotMatch(SHIM, /static\s*\{/, "class static block");
});

function page(html = "<body><div id='main'><p>Hello</p></div></body>") {
  const posted = [];
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://open.spotify.com/" });
  dom.window.webkit = { messageHandlers: { catalina: { postMessage: o => posted.push(o) } } };
  dom.window.CSS = { supports: () => false };
  return { w: dom.window, posted };
}

test("feature probe reports syntax, API and CSS gaps separately without throwing", () => {
  const { w, posted } = page();
  w.eval(FEATURES);
  const f = posted.find(p => p.type === "features");
  assert.ok(f, "features message");
  assert.ok(Array.isArray(f.syntax) && Array.isArray(f.api) && Array.isArray(f.css));
  // Node 22 parses these, so they must not be reported (it genuinely lacks duplicate named
  // groups, and jsdom has no import maps, so those two may appear and that's correct).
  for (const ok of ["RegExp lookbehind", "class static blocks", "RegExp v flag", "private #x in obj"]) {
    assert.ok(!f.syntax.some(s => s.startsWith(ok)), ok);
  }
  assert.ok(f.css.length > 0, "CSS.supports stubbed false here, so CSS gaps are listed");
  w.close();
});

test("error capture redacts long tokens and strips query strings", () => {
  const { w, posted } = page();
  w.eval(ERRORS);
  const token = "BQD" + "x".repeat(80);
  w.dispatchEvent(new w.ErrorEvent("error", { message: "bad token " + token, filename: "https://open.spotifycdn.com/a.js?secret=1#frag", lineno: 3 }));
  const e = posted.find(p => p.type === "jsError");
  assert.match(e.text, /\[redacted\]/);
  assert.doesNotMatch(e.text, /xxxxxxxxxx/);
  assert.equal(e.src, "https://open.spotifycdn.com/a.js");
  w.console.log("cookie", "sp_dc=" + "A1b2-C3_d4".repeat(6));
  assert.match(posted.find(p => p.type === "console").text, /\[redacted\]/);
  w.close();
});

test("render check reports an empty page as empty", async () => {
  const { w, posted } = page("<body><div id='main'></div></body>");
  w.setTimeout = (fn) => fn();          // don't wait 12 s
  w.eval(RENDER.replace("setTimeout(", "window.setTimeout("));
  const r = posted.find(p => p.type === "render");
  assert.equal(r.root, "#main with 0 elements");
  assert.equal(r.textLength, 0);
  assert.equal(r.unsupported, false);
  w.close();
});
