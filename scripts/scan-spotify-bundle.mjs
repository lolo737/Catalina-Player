#!/usr/bin/env node
/*
 * Compatibility scan of Spotify's public web player, as any browser receives it.
 *
 * Fetches https://open.spotify.com/ the way a browser would (once per browser identity),
 * downloads the JavaScript and CSS files that page references, and reports which language
 * features they use that Safari 15.6, the last Safari for macOS 10.15, does not support.
 *
 * It reads only public files any visitor's browser downloads. It does not sign in, play
 * audio, touch copy protection, or keep the files (only the findings are written out).
 *
 *   node scripts/scan-spotify-bundle.mjs > scan.md     (also writes scan.json)
 */
import * as acorn from "acorn";
import * as walk from "acorn-walk";
import fs from "node:fs";

const IDENTITIES = {
  "safari-15.6 (honest, Catalina)": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.6.1 Safari/605.1.15",
  "safari-18.6 (app default)": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15",
};
const HOME = "https://open.spotify.com/";
const MAX_FILES = 40, MAX_BYTES = 25e6;

// Syntax Safari 15.6 cannot parse: one occurrence makes the whole file fail to load.
const SYNTAX_FAIL = {
  lookbehind: "RegExp lookbehind (?<= / (?<! (Safari 16.4)",
  vflag: "RegExp v flag (Safari 17)",
  dupgroups: "duplicate named capture groups (Safari 17)",
  staticBlock: "class static blocks (Safari 16.4)",
};
// Functions Safari 15.6 lacks: code fails only when the call runs (the app's shim covers these).
const API = {
  "Array toSorted/toReversed/toSpliced/with (16)": /\.(toSorted|toReversed|toSpliced)\(|\.with\(\s*-?\d/g,
  "Object.groupBy / Map.groupBy (17.4)": /\b(Object|Map)\.groupBy\b/g,
  "Promise.withResolvers (17.4)": /\bPromise\.withResolvers\b/g,
  "Array.fromAsync (16.4)": /\bArray\.fromAsync\b/g,
  "Set union/intersection/… (17)": /\.(union|intersection|symmetricDifference|isSubsetOf|isSupersetOf|isDisjointFrom)\(/g,
  "AbortSignal.timeout / any (16 / 17.4)": /\bAbortSignal\.(timeout|any)\b/g,
  "checkVisibility (17.4)": /\.checkVisibility\(/g,
  "String isWellFormed/toWellFormed (16.4)": /\.(isWellFormed|toWellFormed)\(/g,
  "Iterator helpers (18.4, not shimmed)": /\bIterator\.(from|prototype)\b/g,
  "Intl.DurationFormat (16.4, not shimmed)": /\bIntl\.DurationFormat\b/g,
};
const CSS_FEATURES = {
  "container queries (16)": /@container\b|container-type\s*:/g,
  ":has() (15.4, supported)": /:has\(/g,
  "nesting & (16.5)": /\{[^{}]*&[:.\[\s>+~]/g,
  "@layer (15.4, supported)": /@layer\b/g,
  "subgrid (16)": /subgrid/g,
  "color-mix() (16.2)": /color-mix\(/g,
  ":is()/:where() (14, supported)": /:(is|where)\(/g,
};

function regexIssues(pattern, flags) {
  const out = [];
  if (/\(\?<[=!]/.test(pattern)) out.push("lookbehind");
  if (flags.includes("v")) out.push("vflag");
  const names = [...pattern.matchAll(/\(\?<([A-Za-z_$][\w$]*)>/g)].map(m => m[1]);
  if (new Set(names).size !== names.length) out.push("dupgroups");
  return out;
}

function scanJs(src) {
  const found = Object.fromEntries(Object.keys(SYNTAX_FAIL).map(k => [k, 0]));
  const examples = {};
  let ast, mode = "module";
  for (const sourceType of ["module", "script"]) {
    try { ast = acorn.parse(src, { ecmaVersion: "latest", sourceType, allowHashBang: true }); mode = sourceType; break; }
    catch (e) { if (sourceType === "script") return { parseError: e.message }; }
  }
  const note = (k, s) => { found[k]++; (examples[k] ||= s.slice(0, 80)); };
  walk.full(ast, node => {
    if (node.type === "Literal" && node.regex) {
      for (const k of regexIssues(node.regex.pattern, node.regex.flags)) note(k, `/${node.regex.pattern}/${node.regex.flags}`);
    }
    if (node.type === "StaticBlock") note("staticBlock", "class … static { … }");
    if ((node.type === "NewExpression" || node.type === "CallExpression") && node.callee.name === "RegExp"
        && node.arguments[0]?.type === "Literal" && typeof node.arguments[0].value === "string") {
      const flags = node.arguments[1]?.type === "Literal" ? String(node.arguments[1].value) : "";
      for (const k of regexIssues(node.arguments[0].value, flags)) note(k, `RegExp(${JSON.stringify(node.arguments[0].value).slice(0, 60)})`);
    }
  });
  const api = {};
  for (const [name, re] of Object.entries(API)) { const n = (src.match(re) || []).length; if (n) api[name] = n; }
  return { mode, syntax: found, examples, api };
}

function scanCss(src) {
  const out = {};
  for (const [name, re] of Object.entries(CSS_FEATURES)) { const n = (src.match(re) || []).length; if (n) out[name] = n; }
  return out;
}

async function get(url, ua) {
  const res = await fetch(url, { headers: { "User-Agent": ua, "Accept-Language": "en-IE,en;q=0.8" }, redirect: "follow" });
  const text = await res.text();
  return { status: res.status, url: res.url, text };
}

function assetsFrom(html, base) {
  const js = new Set(), css = new Set();
  for (const m of html.matchAll(/<script[^>]+src=["']([^"']+)["']/gi)) js.add(new URL(m[1], base).href);
  for (const m of html.matchAll(/<link[^>]+href=["']([^"']+)["'][^>]*>/gi)) {
    const tag = m[0], href = new URL(m[1], base).href;
    if (/rel=["'](modulepreload|preload)["']/i.test(tag) && /\.m?js(\?|$)/.test(href)) js.add(href);
    if (/rel=["']stylesheet["']/i.test(tag) || /\.css(\?|$)/.test(href)) css.add(href);
  }
  return { js: [...js], css: [...css] };
}

const report = { scannedAt: new Date().toISOString(), identities: {} };
for (const [label, ua] of Object.entries(IDENTITIES)) {
  const r = { };
  try {
    const page = await get(HOME, ua);
    r.status = page.status; r.finalUrl = page.url; r.htmlBytes = page.text.length;
    r.unsupportedText = /Unsupported browser|unavailable on this browser|browser is not supported/i.test(page.text);
    const { js, css } = assetsFrom(page.text, page.url);
    r.jsFiles = js.length; r.cssFiles = css.length; r.files = {};
    let bytes = 0;
    for (const url of [...js, ...css].slice(0, MAX_FILES)) {
      const name = url.replace(/\?.*$/, "");
      try {
        const f = await get(url, ua);
        bytes += f.text.length;
        if (bytes > MAX_BYTES) { r.truncated = true; break; }
        r.files[name] = { status: f.status, bytes: f.text.length,
          ...(/\.css(\?|$)/.test(url) ? { css: scanCss(f.text) } : scanJs(f.text)) };
      } catch (e) { r.files[name] = { error: String(e.message || e) }; }
    }
  } catch (e) { r.error = String(e.message || e); }
  report.identities[label] = r;
}
fs.writeFileSync("scan.json", JSON.stringify(report, null, 2));

// Markdown summary
const lines = [`# Spotify web player: Safari 15.6 compatibility scan`, ``, `Scanned ${report.scannedAt}. Public files only; nothing kept but these findings.`, ``];
for (const [label, r] of Object.entries(report.identities)) {
  lines.push(`## Identity: ${label}`, ``);
  if (r.error) { lines.push(`Fetch failed: ${r.error}`, ``); continue; }
  lines.push(`- HTTP ${r.status}, ${r.htmlBytes} bytes of HTML from ${r.finalUrl}`,
             `- "Unsupported browser" text in the HTML: **${r.unsupportedText ? "yes" : "no"}**`,
             `- ${r.jsFiles} script files, ${r.cssFiles} stylesheets referenced${r.truncated ? " (scan truncated)" : ""}`, ``);
  const syntaxTotals = {}, apiTotals = {}, cssTotals = {}, bad = [];
  for (const [file, f] of Object.entries(r.files || {})) {
    if (f.parseError) bad.push(`${file}: ${f.parseError}`);
    for (const [k, n] of Object.entries(f.syntax || {})) if (n) { syntaxTotals[k] = (syntaxTotals[k] || 0) + n; }
    for (const [k, n] of Object.entries(f.api || {})) apiTotals[k] = (apiTotals[k] || 0) + n;
    for (const [k, n] of Object.entries(f.css || {})) cssTotals[k] = (cssTotals[k] || 0) + n;
  }
  const filesWithSyntax = Object.entries(r.files || {}).filter(([, f]) => f.syntax && Object.values(f.syntax).some(Boolean));
  lines.push(`**Syntax Safari 15.6 cannot parse** (a file containing any of these fails to load at all):`, ``);
  if (!Object.keys(syntaxTotals).length) lines.push(`- none found`);
  for (const [k, n] of Object.entries(syntaxTotals)) lines.push(`- ${SYNTAX_FAIL[k]}: ${n}`);
  for (const [file, f] of filesWithSyntax) lines.push(`  - in \`${file.split("/").pop()}\`: ${Object.entries(f.examples).map(([k, e]) => `${k} e.g. \`${e}\``).join("; ")}`);
  lines.push(``, `**Functions Safari 15.6 lacks** (fail only when called; the app's shim covers most):`, ``);
  if (!Object.keys(apiTotals).length) lines.push(`- none found`);
  for (const [k, n] of Object.entries(apiTotals)) lines.push(`- ${k}: ${n} uses`);
  lines.push(``, `**CSS features used:**`, ``);
  if (!Object.keys(cssTotals).length) lines.push(`- none found`);
  for (const [k, n] of Object.entries(cssTotals)) lines.push(`- ${k}: ${n}`);
  if (bad.length) lines.push(``, `Files the scanner itself could not parse: ${bad.join("; ")}`);
  lines.push(``);
}
console.log(lines.join("\n"));
