# Catalina Player audit: why it doesn't work on macOS 10.15

*November 2026 · branch `audit/catalina-2026-11` · audited from commit `024322b` (main at the time) · fixes up to `cc41454`*

**Evidence tiers used throughout:**
- **OBSERVED**: seen in code, in a CI run log, or in a source fetched during the audit.
- **OWNER**: seen by the owner on his Catalina Mac and reported in chat.
- **INFERRED**: follows from observed facts, but wasn't watched happening.
- **UNKNOWN**: not established.

---

## 1. Verdict

**Not fixable on macOS 10.15 with this design. No app built on Catalina's own web engine can run Spotify's current web player.**

Spotify's server decides by browser identity:
- **Safari 15.6 (honest):** it sends a 5 KB "Unsupported browser" page *(OBSERVED: CI scan; OWNER: first build)*.
- **Newer Safari (the app's disguise until now):** it sends the real player. That player's two main script files contain JavaScript syntax Safari 15.6 cannot parse: regex lookbehind in `web-player.2c9a67a0.js`, and class static blocks in `encore~web-player.eadfdb20.js` *(OBSERVED: CI scan)*. WebKit added both in Safari 16.4, in March 2023 *(OBSERVED: WebKit blog, caniuse)*. Catalina's last Safari is 15.6.1, from August 2022 *(OBSERVED: MacRumors)*. A file with a syntax error doesn't run at all, so the player never starts, which explains the blank window *(INFERRED, matching the OWNER's blank/logged-out reports)*.

The wrapper itself is sound. Built from this same source and run on GitHub's macOS 15.8.2 Mac, it loads the full player: 2,810 elements and the player bar, with nothing missing *(OBSERVED: CI control run)*.

The only ways to make the current player run inside Catalina's WebKit would be:
- rewriting Spotify's code on the fly; or
- swapping the browser engine for one Spotify still accepts.

The first modifies Spotify's service and is out of scope (§7). The second means shipping a different, DRM-licensed engine; see §9 for what that involves. **The working answer on Catalina today is Firefox**, which is current and still supports 10.15 *(INFERRED: the Firefox 153 ESR release notes, July 2026, drop support only for 10.14 and below)*.

---

## 2. What "doesn't work" meant

| # | What the owner saw (OWNER, 28 Oct 2026) | Identity sent | Explained by |
|---|---|---|---|
| 1 | "Unsupported browser · Spotify is unavailable on this browser" | Safari 15.6.1 (first build) | The server gate (§3, RC1) |
| 2 | Login page appears with icons overlapping the text; "Continue" after the email loops back | Safari 18.6 disguise | Sign-in pages work partly; the overlap is CSS the old engine lacks. *Why* it loops is UNKNOWN (§10) |
| 3 | White and black screens mid-sign-in | Disguise, with the identity switched per page | Reloading mid-redirect broke the flow; reverted in `fa93c4d` |
| 4 | After pasting `sp_dc`: "still logged out", or a blank screen | Disguise | The signed-in player can't run its code on 15.6 (RC2) |
| 5 | App launches; the Dock icon showed "?" once | n/a | A stale Dock shortcut, not a crash. Gatekeeper isn't the cause |

### Decision tree: which log line tells you which failure

`~/Library/Logs/CatalinaPlayer.log`, current branch:

```
App won't open at all?
├─ "damaged"/"can't be opened"        → Gatekeeper quarantine: xattr -cr the app (§8 step 2)
└─ opens → read the log:
   ├─ "LOAD ERROR NSURLErrorDomain …"  → network. The window shows "Can't reach Spotify · Try again"
   ├─ "SPOTIFY SAYS Unsupported browser"
   │   or "RENDER … says UNSUPPORTED BROWSER"  → RC1: server gate (expected on 10.15 with the honest identity)
   ├─ "JS SyntaxError … (open.spotifycdn.com/…web-player….js:…)"
   │   + "RENDER … root #main with 0 elements" → RC2: code can't parse on this engine (blank window)
   ├─ "FEATURES … SYNTAX missing: RegExp lookbehind…; class static blocks…" → confirms RC2 is unavoidable here
   ├─ "DRM com.apple.fps: refused …"     → copy protection unavailable (would block playback even if RC1 and RC2 were solved)
   └─ "RENDER … N elements, player bar"   → the player is drawn. Next limit is sign-in or playback
```

---

## 3. Root-cause analysis

**RC1: server-side browser gate (OBSERVED).**
- The CI scan fetched `https://open.spotify.com/` twice:
  - With the Safari 15.6.1 identity: HTTP 200, 5,144 bytes, "Unsupported browser" text present.
  - With the Safari 18.6 identity: HTTP 200, 169,313 bytes, the real player.
  - Source: [run 44928870705, job *scan*](https://github.com/lolo737/catalina-player/actions/runs/44928870705).
- Spotify's help page says desktop browsers must be "updated within the last 30 months" (§6).
- In the app, the identity sent is `PlayerWindowController.defaultUserAgent` (`Sources/PlayerWindowController.swift:53` @ `024322b`), applied in `setUpWebView` (`:113`, `view.customUserAgent`).
- `Scripts.watchForProblems` (`Sources/Scripts.swift:17`) spots the page and offers Firefox.

**RC2: the player's code uses syntax Safari 15.6 can't parse (OBSERVED in the code; effect on 10.15 INFERRED).**
- With the disguise, the scan parsed every script with a full JavaScript parser (`scripts/scan-spotify-bundle.mjs`, Acorn AST):
  - Regex lookbehind × 2, e.g. `/(?<=\s|^)\*([^*]+)\*(?=\s|$|[.,!?;:])/g` in `web-player.2c9a67a0.js`.
  - Class static blocks × 7, in `encore~web-player.eadfdb20.js`.
- Function-level gaps were also found, but those can be shimmed: `Set` methods × 9, `checkVisibility` × 4, `AbortSignal.timeout/any` × 2, `Promise.withResolvers` × 1, `toSorted`-family × 1.
- In CSS: container queries × 28 (Safari 16) and `color-mix()` × 1 (16.2).
- The `featureScript` in use at `024322b` (`Sources/Diagnostics.swift:109`) reported this to the owner's log only as a flat list. It ran *after* page scripts, so it couldn't tell syntax from functions.

**RC3: the disguise made things worse, not better (INFERRED).**
- It turned an honest "Unsupported browser" page (with a Firefox offer) into a blank window and a looping sign-in.
- It is also the part of the app most at odds with Spotify's User Guidelines on circumventing its technology (§11).

**Hypotheses from the brief:**

| | Hypothesis | Result |
|---|---|---|
| a | Engine too old for the web client | **Confirmed.** OBSERVED (RC1, RC2) |
| b | DRM in a third-party WKWebView | macOS 15.8.2: FairPlay (`com.apple.fps`) **granted**, Widevine refused, legacy `WebKitMediaKeys` FairPlay yes. OBSERVED, CI control run. On 10.15: **UNKNOWN**; the new probe logs it. Not the cause, because the player never gets that far |
| c | The user agent rejected, or mismatched with the engine | **Confirmed**, as RC1 and RC3 |
| d | Sign-in popups blocked by `Hosts.keepInside` (`:12`) | Not the cause. Google, Apple and Facebook domains are allowlisted; redirects aren't blocked (only `linkActivated` leaves the app, `:498` @ `024322b`); popups get the same configuration. OBSERVED in code. The email loop itself is UNKNOWN (§10) |
| e | Code signing, notarisation, Gatekeeper | Not the cause: OWNER launched it. Builds are ad-hoc signed, not notarised (§11, R6) |

---

## 4. Build and runtime assumptions for 10.15

| Assumption | Status |
|---|---|
| `LSMinimumSystemVersion` 10.15 (`Resources/Info.plist`) | OBSERVED |
| Intel binary records `minos 10.15`, built with SDK 15.5 on GitHub's image | OBSERVED, [run 44930014585](https://github.com/lolo737/catalina-player/actions/runs/44930014585) |
| Links only system libraries: AppKit, WebKit, MediaPlayer, and the Swift runtime in `/usr/lib/swift` | OBSERVED (`otool -L`, same run). The Swift runtime has shipped with macOS since 10.14.4 (INFERRED). The app launched on Catalina (OWNER) |
| Private settings `developerExtrasEnabled` and `drawsBackground` set via key-value coding (`:126`, `:247` @ `024322b`) | Undocumented API that could crash on an unknown key. Worked on the owner's 10.15 (OWNER) and on macOS 15 (OBSERVED) |
| `./build.sh` on Catalina needs Apple's command line tools. The newest for 10.15 is Xcode 12.4 / Swift 5.3 | Whether today's source compiles with Swift 5.3 is **UNKNOWN**. CI compiles with the current toolchain |
| GitHub `macos-14` runner image | **Retired**: "The configuration 'macos-14-arm64-us-default' is not supported" (OBSERVED, run 44928870705). The **Build app** workflow on `main` still uses it, so new release builds fail until this branch is merged |

---

## 5. Patches on `audit/catalina-2026-11` (pushed, **not merged**)

| Commit | What |
|---|---|
| `a339568` | **Compat shim** (`Sources/Compat.swift`): self-written polyfills that fill gaps only. **Probe split** into SYNTAX / API / CSS, injected *before* the shim (`Diagnostics.featureScript`). **DRM probe** (which key systems the engine grants; nothing played). **Render check** that reports blank pages. Error text redacted like console text. **Caps on page messages** in Swift (`handle`). **Error page with Retry** instead of a silent black window. **SelfTest** (`--selftest`, `--ua`). The bundle scanner and the `selftest.yml` workflow. 10 new tests |
| `091f3ed` | **Honest identity by default**: reads the real Safari version from `/Applications/Safari.app`. The disguise becomes opt-in (`defaults write … UserAgent modern`). Both workflows move to `macos-15` |
| `7453c32` | Self-test prints its results into the job log |
| `7fb88ab` | Self-test `--hostile` (message flood) and `--home` (offline) runs |
| `cc41454` | Every log line capped at 1,200 characters. CI also checks that the 10.15 Intel build compiles |
| (this commit) | README: status warning, stronger disclaimer, accurate claims. This AUDIT.md |

The shim does **not** fix Spotify on Catalina: it can't fix syntax. It stays because it's harmless (a no-op where functions exist: OBSERVED, `compat: []` on macOS 15), it helps other sites, and its log line separates "fixable" from "not fixable".

---

## 6. Test matrix

**Tests run here:**
- `npm test`: 14/14 pass (OBSERVED, locally and in CI).
- The 4 original tests use mock `data-testid` selectors (`control-button-playpause`, `control-button-skip-forward/back`, `context-item-info-title/artist`). Spotify's live HTML couldn't be read from this workspace, so whether those still match is **UNKNOWN**.
- On macOS 15, the self-test found `[data-testid="control-button-playpause"]` present (`playerBar: true`, OBSERVED).

| Case | Expected | How tested | Result | Severity |
|---|---|---|---|---|
| Player on a modern engine | Full player renders | CI macOS 15.8.2, honest + disguise | ✅ 2,810 elements, player bar, no missing features | n/a |
| Player on Catalina, honest identity | Unsupported page + Firefox offer | CI scan (server response) + OWNER | ✅ gate observed; offer is code-read | **Blocker** (Spotify-side) |
| Player on Catalina, disguise | Works (old belief) | CI scan of served code | ❌ syntax 15.6 can't parse → blank | **Blocker** (Spotify-side) |
| Offline / bad host at start | Readable error + retry | CI `--home https://…invalid/` | ✅ "Can't reach Spotify … Try again" (was a black window) | Fixed (was Medium) |
| Malformed / oversized / flooding messages to `catalina` handler | No crash, bounded log | CI `--hostile`: 5,517 messages incl. 1 MB strings, wrong types, nulls | ✅ no crash; console capped 1,500, JS errors 80; log 73 KB; longest line 4,943 → fixed to ≤1,221 | Fixed (was Low) |
| Huge console output | Bounded | Same run | ✅ cap held | n/a |
| Diagnostics log growth over a long session | Bounded | Code reading | ⚠️ Navigation lines are uncapped (small); file resets each launch | Low |
| Secrets in the log | None | Tests: tokens ≥40 chars redacted in console + errors; query values and fragments dropped; cookie logged only as a length | ✅ | n/a |
| Expired / cleared session | Sign-in offered | Code reading (`checkSession`, `:304`) | ✅ | n/a |
| Login popups | Open in small window, close on `window.close()` | Code reading (`createWebViewWith`, `webViewDidClose`) | ✅ in code; not exercised (no sign-in in CI) | n/a |
| URL outside the allowlist | Opens in the default browser | Code reading (`decidePolicyFor`) | ✅ for clicked links; **redirects to any host stay inside** | Low |
| Any site loaded in the window can post to the handler | Only logs / one alert | Hostile run | ✅ effects bounded; a page *can* fake a "SPOTIFY SAYS" line and trigger the Firefox alert once | Low |
| Zoom limits | 0.6×–2.0× | Code reading (`zoomInPage/OutPage`) | ✅ clamped | n/a |
| Close window, reopen from Dock | Hides, keeps playing, reopens | Code reading | ✅; real-Mac check below | n/a |
| Sleep / wake, media-key mashing, clean first launch | No crash, keys work | Can't run in CI | **Owner test**, §8 | UNKNOWN |
| 10.15 Intel build compiles | Yes | CI macOS 15 + `vtool` | ✅ `minos 10.15` | n/a |
| Build workflow on `main` | Builds | CI annotation | ❌ `macos-14` retired; fixed on branch | **High** until merged |

**Ranked open bugs:**
1. **High:** release workflow on `main` broken (merge the branch).
2. **Medium:** the session-cookie "side door" encourages handling a live session token, and the owner pasted one into a chat. Keep it, but with the new README warning; consider removing it from the welcome screen.
3. **Low:** redirects to non-allowlisted hosts stay in the window.
4. **Low:** a page can spoof one "Spotify says" alert.
5. **Low:** navigation log lines are uncapped.
6. **UNKNOWN:** whether the source compiles with Swift 5.3 (`./build.sh` on Catalina itself).

---

## 7. Reverse-engineering analysis: what was done, and where the line is

**Done (permitted):**
- Fetched the public HTML and script files any visitor's browser downloads, from GitHub's servers, without signing in.
- Parsed them to list language features.
- Kept only counts and short examples; Spotify's code was not stored in the repo.
- Probed this app's own engine for features and for which DRM key systems it grants, using the standard EME call (no keys, no content).

**Not done, and refused if needed:**
- Rewriting or re-serving Spotify's scripts (for example, transpiling lookbehind on the fly through a custom URL scheme). That is the one technical route that *might* make the player parse on 15.6. It modifies Spotify's service and sits against its User Guidelines (§11). Flagged, not attempted.
- Bypassing the "Unsupported browser" gate as a product feature: the disguise is now opt-in only.
- Anything touching FairPlay/Widevine, keys, tokens, audio capture or Premium restrictions.
- Decompiling Spotify's desktop app.

---

## 8. Owner test on a real Catalina Mac

Get a build of this branch. Either merge it into `main` and run **Actions → Build app** (the download appears there as before), or on the Mac run `git checkout audit/catalina-2026-11 && ./build.sh`. Then:

1. **Clean first launch.** Quit Catalina Player. In Terminal:
   ```
   defaults delete io.github.lolo737.catalinaplayer 2>/dev/null; rm -f ~/Library/Logs/CatalinaPlayer*
   ```
2. If macOS says "damaged":
   ```
   xattr -cr "/Applications/Catalina Player.app"
   ```
3. **Unattended self-test**, honest identity, then the disguise. About 50 seconds each:
   ```
   APP="/Applications/Catalina Player.app/Contents/MacOS/CatalinaPlayer"
   "$APP" --selftest 45 --ua honest;  cp ~/Library/Logs/CatalinaPlayer.log ~/Desktop/cp-honest.log; cp ~/Library/Logs/CatalinaPlayer-selftest.* ~/Desktop/ 2>/dev/null
   "$APP" --selftest 45 --ua modern;  cp ~/Library/Logs/CatalinaPlayer.log ~/Desktop/cp-modern.log
   ```
4. **Send back:** `cp-honest.log`, `cp-modern.log` and `CatalinaPlayer-selftest.png`. They hold no cookie values, passwords or query values. **Never paste `sp_dc` anywhere.** Lines to look for:
   - `FEATURES … SYNTAX missing`
   - `DRM`
   - `RENDER`
   - `JS SyntaxError …`
5. **By hand:**
   - Close the window (⌘W). Click the Dock icon: it comes back.
   - Put the Mac to sleep and wake it. The app should still respond.
   - Press ⏯ ⏭ ⏮ ten times quickly. Nothing should crash; there's no music, so nothing plays.
   - Unplug the network and relaunch: you should see "Can't reach Spotify · Try again".
6. **The real fallback:** in Firefox on the same Mac, open open.spotify.com, sign in, play a song. Report whether it plays. That's the working route on 10.15.

**Virtual machines:** Apple's macOS licence allows up to two extra macOS copies in VMs, only on Apple-branded hardware you own, for listed purposes including personal non-commercial use. That's section 2B(iii) of the Monterey licence; older licences are similar ([Eclectic Light](https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/)). A Catalina VM needs an Intel Mac. Cloud Macs run current macOS, not 10.15.

---

## 9. Spotify on Catalina: version history

| Date | Event | Source |
|---|---|---|
| Sep 2017 | Spotify's web player stops supporting Safari | [MacRumors, 15 May 2020](https://www.macrumors.com/2020/05/15/spotify-web-player-support-safari-browser-restored/) |
| May 2020 | Safari support restored after "over two-and-a-half years" | same |
| 18 Aug 2022 | Safari 15.6.1, the last Safari for Catalina | [MacRumors](https://www.macrumors.com/2022/08/18/safari-security-update-macos-big-sur-catalina/) |
| 27 Mar 2023 | Safari 16.4 adds regex lookbehind and class static blocks (never available on Catalina) | [WebKit blog](https://www.webkit.org/?p=13966), [caniuse](https://caniuse.com/mdn-javascript_classes_static_initialization_blocks) |
| Jan–Aug 2024 | Chrome 128 is the last Chrome for 10.15 | [Chromium embedder-dev](https://groups.google.com/a/chromium.org/g/embedder-dev/c/7krCQcXLq1Y) |
| Undated | Desktop installer says "for macOS 11.0 or later". Community answer: minimum "OS X 11.0 or above". A user reports desktop 1.1.93.896 still working on Catalina (unverified, no date) | [Spotify Community](https://community.spotify.com/t5/Desktop-Mac/Cant-download-Spotify-on-Mac-OS-10-15-7/m-p/7074832) |
| Undated | Later community answer: minimum now 12.0 | [Spotify Community](https://community.spotify.com/t5/Desktop-Mac/Search-function-not-working-any-longer-not-able-to-update/td-p/7486475) |
| Nov 2026 | Spotify's own table: desktop app needs "OS X 13.0 or above" | [Spotify Support: supported devices](https://support.spotify.com/us/article/supported-devices-for-spotify/) |
| Nov 2026 | Web player: desktop browsers "updated within the last 30 months" (Baseline widely available) | [Spotify Support: web player](https://support.spotify.com/us/article/webplayer/), [web.dev Baseline](https://web.dev/blog/baseline-definition-update) |
| Jul 2026 | Firefox 153 ESR drops only macOS 10.14 and below, which implies Catalina is still supported (not stated outright) | [Firefox 153 ESR notes](https://www.firefox.com/en-US/firefox/153.0esr/releasenotes/) |

The exact date Spotify's desktop app dropped 10.15 is **UNKNOWN**: no dated official source was found. Old desktop builds are not linked or recommended here: don't install them from mirror sites.

---

## 10. What could not be verified

- Spotify's current HTML and scripts were read from GitHub's servers (US), not from Ireland. Differences by region are possible but unlikely.
- Whether Catalina's WKWebView would grant FairPlay to Spotify (moot until RC2).
- Why the email "Continue" loops on 10.15 with the disguise. Likely the same class of failure, but not observed.
- Whether the original test selectors match Spotify's signed-in player bar today (the play/pause button was observed signed out).
- Whether the source compiles with Swift 5.3 (`./build.sh` on Catalina).
- Sleep/wake, media keys, real sign-in and real playback: these need a Mac and an account (§8).
- Whether Firefox's Widevine module still installs on 10.15 (owner test, §8 step 6).

**If Catalina must keep a Spotify window,** the next three options, in order:
1. **Firefox on 10.15.** Supported today. Make the app a one-click Firefox launcher on Catalina.
2. **Upgrade macOS.** OpenCore Legacy Patcher can install newer macOS on many unsupported Macs. It's unofficial; check the Mac model; back up first.
3. **A different engine**, for example Electron with the castLabs Widevine build. This is heavy and needs Widevine signing. Chromium-based engines also dropped 10.15 at version 128, which falls outside Spotify's 30-month window around early 2027. Not recommended.

---

## 11. Risk review

*I'm not a lawyer, and this isn't legal advice. Quotes are kept under 15 words.*

**What the sources say:**
- **Spotify Terms of Use** (updated 4 Sep 2026): the service is licensed for personal, non-commercial use. They grant "no rights to use" Spotify's brand features. Third-party apps aren't guaranteed to work ([Terms](https://www.spotify.com/us/legal/end-user-agreement)).
- **Spotify User Guidelines**, which are part of the Terms ([guidelines](https://www.spotify.com/legal/user-guidelines)), prohibit:
  - "reverse-engineering, decompiling, disassembling", except where law allows;
  - "circumventing any technology used by Spotify";
  - "crawling" or "scraping";
  - "using the Spotify logo without permission".
- **Developer Policy** (15 May 2025): it covers apps built on Spotify's platform; whether it reaches an app that uses no Spotify API or SDK, like this one, isn't clear from the policy page, so treat it as guidance. App names must not include "Spotify" or begin with "Spot". No implied endorsement ([policy](https://developer.spotify.com/policy/), [branding](https://developer.spotify.com/documentation/design)).
- **EU law:** Software Directive 2009/24/EC, Art. 6, allows decompilation only to make an independent program interoperate, limited to what's needed ([text](https://www.legislation.gov.uk/eudr/2009/24/article/6)). That's implemented in Ireland's Copyright and Related Rights Act 2000 and Germany's UrhG §§69d–69e. This app decompiles nothing. Separately, EU law protects technical protection measures (InfoSoc Directive 2001/29/EC, Art. 6); the app doesn't touch them.
- **Apple:** apps distributed outside the App Store should be signed with a Developer ID and notarised so Gatekeeper trusts them. That needs a paid Apple Developer Program membership ([Apple](https://developer.apple.com/developer-id)).

**Risk register:**

| # | Risk | Likelihood | Impact | Mitigation (done = on this branch) | Source |
|---|---|---|---|---|---|
| R1 | Identity disguise read as "circumventing technology used by Spotify" | Medium (it was the default) | Account action, takedown request | **Done:** honest by default; disguise opt-in only, documented as an experiment | User Guidelines |
| R2 | Users led to paste live `sp_dc` session tokens (one already leaked into a chat) | Medium | Account takeover | README warning (done). Consider removing the side door; tell users to use "Sign out everywhere" if leaked | n/a |
| R3 | Implying affiliation via name, icon, colours or screenshots | Low | Trademark complaint | Name has no "Spotify"; own vinyl icon in orange, not Spotify green; disclaimer strengthened (done). Don't add Spotify logos or screenshots of Spotify's UI | Terms §3, Branding |
| R4 | Media-key scripts pressing Spotify's buttons read as "automation" | Low | Low | User-initiated clicks only; no play-count inflation; documented | User Guidelines |
| R5 | Recommending old Spotify desktop builds from mirrors | Low (not done) | Malware, ToS | Not linked; README advises against | n/a |
| R6 | Unsigned, un-notarised downloads | High (always) | Users bypass Gatekeeper | Recommend building from source; or Developer ID + notarisation if distributing widely | Apple |
| R7 | Diagnostics leaking secrets | Low | Medium | Cookie value never logged (length only); query values and fragments dropped; long tokens redacted in console and errors; lines capped (done, tested) | tests |
| R8 | Cookie stored on disk | Inherent | As any browser | WebKit's own cookie store for this app's ID; *Sign Out and Clear Data* wipes it | n/a |

**Licence:** MIT is fine for this code (and already in place). The embedded fonts stay under the SIL OFL (`Resources/FONT-LICENSES.txt`).

**Public or private?** It can stay public once this branch is merged. The merge brings the honest identity, the status warning and the disclaimer (README "What it is"). Until then, `main` still ships the disguise by default and the old "dependable route" wording for cookies. If the merge waits, consider making the repo private in the meantime.

**README disclaimer text** (now in the README):

> **Unofficial.** Catalina Player is an independent project. It isn't made, endorsed, sponsored or supported by Spotify, and isn't affiliated with Spotify AB. You sign in with your own Spotify account directly on Spotify's own pages, and Spotify's Terms of Use apply as normal. The app doesn't block, skip or alter anything Spotify shows you, adverts included. It doesn't store, record, download or redistribute any music, and it doesn't touch Spotify's copy protection: playback, where it works at all, is handled by macOS's own WebKit exactly as in Safari. "Spotify" is used only to say what the app opens; the name and icon are its own.

---

*CI evidence: [scan, first run](https://github.com/lolo737/catalina-player/actions/runs/44928870705) · [control on macOS 15](https://github.com/lolo737/catalina-player/actions/runs/44929293897) · [hostile + offline](https://github.com/lolo737/catalina-player/actions/runs/44929604040) · [10.15 build check](https://github.com/lolo737/catalina-player/actions/runs/44930014585)*
