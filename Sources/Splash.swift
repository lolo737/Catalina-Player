import Foundation

/// The old-school loading screen shown over the player at launch.
/// A terminal log shows what the app is really doing (versions, checks, timings), then, if you're not signed in,
/// lays out the two ways to sign in. Talks to the app through `catalinaSplash` messages:
///   hello · signIn · cookie · skip     (app → page: window.cp.update({session, loaded}))
enum Splash {
    static let html = #"""
<!doctype html>
<html><head><meta charset="utf-8">
<style>
  :root { --amber:#FFB45C; --green:#7CFFB0; --cream:#FBEFDF; --dim:rgba(251,239,223,.55); }
  * { box-sizing:border-box; margin:0; padding:0; }
  html,body { height:100%; overflow:hidden; cursor:default; -webkit-user-select:none; }
  body { font:13px/1.55 Menlo, Monaco, monospace; color:var(--cream);
    background: radial-gradient(120% 90% at 50% 120%, #E07A3E 0%, #7A3657 30%, #2E1A55 62%, #0F1230 100%); }
  .crt::before { content:""; position:fixed; inset:0; pointer-events:none; z-index:9;
    background:repeating-linear-gradient(0deg, rgba(0,0,0,.18) 0 1px, transparent 1px 3px); }
  .crt::after { content:""; position:fixed; inset:0; pointer-events:none; z-index:10;
    background:radial-gradient(ellipse at center, transparent 55%, rgba(0,0,0,.55) 100%); }
  .wrap { height:100%; display:flex; flex-direction:column; align-items:center; justify-content:center; padding:28px; }
  .banner { display:flex; align-items:center; margin-bottom:22px; }
  .vinyl { width:74px; height:74px; border-radius:50%; margin-right:22px; flex:none;
    background: radial-gradient(circle, #0D0D12 0 6%, #FAB060 7% 20%, #F2803A 21% 36%, #0D0D12 37% 40%,
      #22222c 41% 42%, #0D0D12 43% 50%, #22222c 51% 52%, #0D0D12 53% 62%, #22222c 63% 64%, #0D0D12 65%);
    box-shadow:0 10px 30px rgba(0,0,0,.5); animation:spin 1.8s linear infinite; }
  @keyframes spin { to { transform:rotate(360deg); } }
  h1 { font:900 46px/1 "Arial Black", Impact, sans-serif; letter-spacing:2px; text-transform:uppercase;
    background:linear-gradient(180deg, #FFF3D6 0%, #FFB45C 55%, #E0602A 100%); -webkit-background-clip:text; color:transparent;
    filter:drop-shadow(3px 3px 0 #2E1A55) drop-shadow(5px 5px 0 rgba(0,0,0,.35)); }
  .tag { color:var(--dim); letter-spacing:3px; font-size:11px; margin-top:8px; text-transform:uppercase; }
  .loader { width:min(620px, 92vw); }
  .bar { display:flex; height:22px; padding:3px; border:2px solid var(--cream); background:rgba(0,0,0,.35); }
  .seg { flex:1; margin-right:3px; background:rgba(255,255,255,.06); }
  .seg:last-child { margin-right:0; }
  .seg.on { background:linear-gradient(180deg, #FFD08A, #F2803A); box-shadow:0 0 8px rgba(255,160,80,.7); }
  .meta { display:flex; justify-content:space-between; margin:8px 0 16px; font-weight:bold; letter-spacing:2px; }
  .blink { animation:blink 1s steps(1) infinite; }
  @keyframes blink { 50% { opacity:0; } }
  .term { width:min(620px, 92vw); height:236px; overflow:hidden; padding:12px 14px; border-radius:8px;
    background:rgba(5,5,14,.82); border:1px solid rgba(255,255,255,.14); box-shadow:inset 0 0 30px rgba(0,0,0,.6); }
  .term .l { white-space:pre; overflow:hidden; text-overflow:ellipsis; }
  .ok { color:var(--green); } .warn { color:var(--amber); } .mute { color:var(--dim); }
  .cursor { display:inline-block; width:8px; height:14px; background:var(--green); vertical-align:-2px; animation:blink 1s steps(1) infinite; }
  .signin { width:min(620px, 92vw); margin-top:16px; display:none; }
  .signin.show { display:block; animation:pop .35s ease-out; }
  @keyframes pop { from { transform:scale(.96); opacity:0; } }
  .signin h2 { font:bold 12px Menlo, monospace; letter-spacing:3px; color:var(--amber); margin-bottom:10px; text-transform:uppercase; }
  .methods { display:flex; }
  .m { flex:1; display:flex; flex-direction:column; padding:14px; margin-right:12px; border:2px solid rgba(251,239,223,.35); border-radius:8px; background:rgba(0,0,0,.35); }
  .m:last-child { margin-right:0; }
  .m .n { color:var(--amber); font-weight:bold; font-size:11px; letter-spacing:2px; }
  .m .t { font:bold 16px "Arial Black", sans-serif; margin:4px 0 6px; }
  .m p { color:var(--dim); font-size:12px; flex:1; }
  kbd { display:inline-block; padding:1px 6px; border:1px solid var(--cream); border-bottom-width:3px; border-radius:4px; font:bold 12px Menlo; color:var(--cream); }
  button { margin-top:12px; width:100%; padding:9px; font:bold 12px Menlo, monospace; letter-spacing:1px; cursor:pointer;
    color:#1A1230; background:var(--cream); border:0; border-radius:6px; box-shadow:0 3px 0 #9b6a3a; }
  button:active { transform:translateY(2px); box-shadow:0 1px 0 #9b6a3a; }
  .skip { display:block; margin:12px auto 0; width:auto; padding:4px 10px; background:none; color:var(--dim); box-shadow:none; text-decoration:underline; }
</style></head>
<body class="crt"><div class="wrap">
  <div class="banner">
    <div class="vinyl"></div>
    <div><h1>Catalina Player</h1><div class="tag">For the Macs the music left behind</div></div>
  </div>
  <div class="loader">
    <div class="bar" id="bar"></div>
    <div class="meta"><span id="label">LOADING<span class="blink">_</span></span><span id="pct">0%</span></div>
  </div>
  <div class="term" id="term"></div>
  <div class="signin" id="signin">
    <h2>&#9656; Two ways to sign in</h2>
    <div class="methods">
      <div class="m"><div class="n">METHOD 01</div><div class="t">Normal sign-in</div>
        <p>Spotify's own sign-in page: email, Google, Facebook or Apple. Any time from the menu: <kbd>&#8679;&#8984;L</kbd></p>
        <button id="b1">SIGN IN NORMALLY</button></div>
      <div class="m"><div class="n">METHOD 02</div><div class="t">Session cookie</div>
        <p>If the normal page loops: sign in once in Firefox, copy the <b>sp_dc</b> cookie, paste it here. Treat it like a password.</p>
        <button id="b2">PASTE A SESSION COOKIE</button></div>
    </div>
    <button class="skip" id="b3">just show me Spotify (Esc)</button>
  </div>
</div>
<script>
(function () {
  // Everything printed here is sent by the app as it happens: real versions, real checks,
  // real timings. The page only draws it.
  var bar = document.getElementById('bar'), term = document.getElementById('term');
  var segs = [], shown = 0, target = 0;
  for (var i = 0; i < 24; i++) { var s = document.createElement('div'); s.className = 'seg'; bar.appendChild(s); segs.push(s); }
  function post(action) { try { window.webkit.messageHandlers.catalinaSplash.postMessage({ action: action }); } catch (e) {} }
  setInterval(function () {
    if (shown < target) shown = Math.min(target, shown + 1);
    document.getElementById('pct').textContent = shown + '%';
    var on = Math.round(shown / 100 * segs.length);
    for (var i = 0; i < segs.length; i++) segs[i].className = 'seg' + (i < on ? ' on' : '');
  }, 18);
  function esc(t) { return String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function add(html) {
    var old = term.querySelector('.cursor'); if (old) old.remove();
    var d = document.createElement('div'); d.className = 'l'; d.innerHTML = html + ' <span class="cursor"></span>';
    term.appendChild(d);
    while (term.children.length > 11) term.removeChild(term.firstChild);
    term.scrollTop = term.scrollHeight;
  }
  window.cp = {
    // {t: text, r: result, c: css class, p: percent}
    log: function (o) {
      var t = esc(o.t || '');
      if (o.r) {
        var pad = 46 - (o.t || '').length, d = ''; while (pad-- > 0) d += '.';
        add('<span class="mute">&gt;</span> ' + t + ' <span class="mute">' + d + '</span> <span class="' + (o.c || 'ok') + '">' + esc(o.r) + '</span>');
      } else {
        add('<span class="' + (o.c || '') + '">' + t + '</span>');
      }
      if (o.p) target = Math.max(target, o.p);
    },
    done: function (signedIn) {
      target = 100;
      document.getElementById('label').textContent = 'READY';
      if (signedIn) {
        add('<span class="ok">&gt; signed in. press play.</span>  <span class="mute">sign-in options any time: &#8679;&#8984;L</span>');
        setTimeout(function () { post('skip'); }, 1800);
      } else {
        add('<span class="warn">&gt; not signed in: pick a method below</span>');
        document.getElementById('signin').className = 'signin show';
      }
    }
  };
  document.getElementById('b1').onclick = function () { post('signIn'); };
  document.getElementById('b2').onclick = function () { post('cookie'); };
  document.getElementById('b3').onclick = function () { post('skip'); };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') post('skip'); });
  post('hello');
})();
</script></body></html>
"""#
}
