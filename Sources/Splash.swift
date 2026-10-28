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
  /* Same look as docs/how-it-works.png: dusk sky, stars, serif title, orange accents, square corners. */
  :root { --cream:#FBEFDF; --orange:#F59A52; --green:#7CFFB0; --dim:rgba(255,255,255,.62); --line:rgba(255,255,255,.14); }
  * { box-sizing:border-box; margin:0; padding:0; border-radius:0; }
  html,body { height:100%; overflow:hidden; cursor:default; -webkit-user-select:none; }
  body { font:15px/1.5 "Avenir Next", "DM Sans", "Helvetica Neue", sans-serif; color:#fff;
    background:linear-gradient(180deg, #0F1230 0%, #2E1A55 50%, #7A3657 82%, #D9773F 100%); }
  .glow { position:fixed; left:50%; bottom:-260px; width:1300px; height:520px; margin-left:-650px; border-radius:50%;
    background:#FF9A4D; opacity:.5; filter:blur(140px); pointer-events:none; }
  .star { position:fixed; width:3px; height:3px; border-radius:50%; background:rgba(255,255,255,.5); }
  .page { position:relative; height:100%; display:flex; flex-direction:column; padding:40px 56px 28px; }
  header { display:flex; align-items:center; justify-content:space-between; }
  .brand { display:flex; align-items:center; }
  .vinyl { width:72px; height:72px; border-radius:50%; margin-right:22px; flex:none;
    background:radial-gradient(circle, #0D0D12 0 6%, #FAB060 7% 21%, #F2803A 22% 37%, #0D0D12 38% 46%,
      #2C2C38 47% 48%, #0D0D12 49% 58%, #2C2C38 59% 60%, #0D0D12 61% 70%, #2C2C38 71% 72%, #0D0D12 73%);
    box-shadow:0 10px 24px rgba(0,0,0,.45); animation:spin 1.8s linear infinite; }
  @keyframes spin { to { transform:rotate(360deg); } }
  h1 { font:400 54px/1 "Instrument Serif", Baskerville, "Hoefler Text", Georgia, serif; color:var(--cream); letter-spacing:-.5px; }
  .sub { color:var(--dim); font-size:16px; margin-top:6px; }
  .chip { font:500 13px Menlo, monospace; color:var(--cream); padding:8px 16px; border:1px solid rgba(255,255,255,.2); background:rgba(255,255,255,.08); }
  main { flex:1; display:flex; flex-direction:column; width:min(760px, 100%); margin:34px auto 0; }
  .blink { animation:blink 1s steps(1) infinite; }
  @keyframes blink { 50% { opacity:0; } }
  .term { flex:1; min-height:120px; max-height:260px; overflow:hidden; padding:6px 4px;
    font:13px/1.6 Menlo, monospace; opacity:.55; background:none; border:0;
    -webkit-mask-image:linear-gradient(180deg, transparent 0, #000 22%, #000 100%); }
  .term .l { white-space:pre; overflow:hidden; text-overflow:ellipsis; color:var(--cream); }
  .ok { color:var(--green); } .warn { color:var(--orange); } .mute { color:rgba(255,255,255,.45); }
  .cursor { display:inline-block; width:8px; height:14px; background:var(--orange); vertical-align:-2px; animation:blink 1s steps(1) infinite; }
  .signin { margin-bottom:22px; display:none; }
  .signin.show { display:block; animation:rise .4s ease-out; }
  @keyframes rise { from { transform:translateY(8px); opacity:0; } }
  .methods { display:flex; }
  .m { flex:1; display:flex; flex-direction:column; padding:20px 22px 22px; margin-right:16px;
    background:rgba(11,11,28,.6); border:1px solid var(--line); box-shadow:0 18px 40px rgba(5,2,20,.5); }
  .m:first-child { border-color:rgba(245,154,82,.9); }
  .m:last-child { margin-right:0; }
  .m .top { font:500 14px Menlo, monospace; color:var(--cream); }
  .m .top b { color:var(--orange); margin-right:8px; }
  .m .role { font:italic 26px/1.2 "Instrument Serif", Baskerville, "Hoefler Text", Georgia, serif; margin:8px 0 6px; }
  .m p { color:rgba(255,255,255,.74); font-size:14px; flex:1; }
  kbd { font:600 12px Menlo, monospace; color:var(--cream); padding:1px 6px; border:1px solid rgba(255,255,255,.4); }
  button { margin-top:16px; padding:11px; font:700 12px Menlo, monospace; letter-spacing:2px; cursor:pointer;
    color:#1A1230; background:var(--cream); border:0; }
  button:hover { background:#fff; }
  button:active { transform:translateY(1px); }
  .skip { display:block; margin:14px auto 0; padding:4px 10px; background:none; color:var(--dim); letter-spacing:1px; text-decoration:underline; }
  .skip:hover { background:none; color:#fff; }
  footer { display:flex; justify-content:space-between; font:12px Menlo, monospace; color:rgba(255,255,255,.55); letter-spacing:1px; }
</style></head>
<body>
<div class="glow"></div>
<div class="page">
  <header>
    <div class="brand">
      <div class="vinyl"></div>
      <div><h1>Catalina Player</h1><div class="sub">Spotify&rsquo;s own web player, in a real Mac window</div></div>
    </div>
    <div class="chip" id="chip">macOS</div>
  </header>
  <main>
    <div class="signin" id="signin">
      <div class="methods">
        <div class="m"><div class="top"><b>01</b>Sign In&hellip; &nbsp;<kbd>&#8679;&#8984;L</kbd></div>
          <div class="role">The front door</div>
          <p>Spotify&rsquo;s own sign-in page: email, Google, Facebook or Apple. Any time from the Catalina Player menu.</p>
          <button id="b1">SIGN IN NORMALLY</button></div>
        <div class="m"><div class="top"><b>02</b>Session cookie</div>
          <div class="role">The side door</div>
          <p>If the front door loops: sign in once in Firefox, copy the <b>sp_dc</b> cookie and paste it here. Treat it like a password.</p>
          <button id="b2">PASTE A SESSION COOKIE</button></div>
      </div>
      <button class="skip" id="b3">just show me Spotify (Esc)</button>
    </div>
    <div class="term" id="term"></div>
  </main>
  <footer><span>SWIFT &middot; APPKIT &middot; WEBKIT &middot; MEDIAPLAYER</span><span>For the Macs the music left behind</span></footer>
</div>
<script>
(function () {
  // Everything printed here is sent by the app as it happens: real versions, real checks,
  // real timings. The page only draws it.
  var term = document.getElementById('term');
  [[9,4],[27,12],[47,6],[63,15],[81,7],[94,18],[19,21],[74,3],[55,19]].forEach(function (p) {
    var st = document.createElement('div'); st.className = 'star'; st.style.left = p[0] + '%'; st.style.top = p[1] + '%';
    document.body.insertBefore(st, document.body.firstChild); });
  var signinShown = false;
  function post(action) { try { window.webkit.messageHandlers.catalinaSplash.postMessage({ action: action }); } catch (e) {} }
  function esc(t) { return String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
  function add(html) {
    var old = term.querySelector('.cursor'); if (old) old.remove();
    var d = document.createElement('div'); d.className = 'l'; d.innerHTML = html + ' <span class="cursor"></span>';
    term.appendChild(d);
    while (term.children.length > 12) term.removeChild(term.firstChild);
    term.scrollTop = term.scrollHeight;
  }
  window.cp = {
    chip: function (t) { document.getElementById('chip').textContent = t; },
    // {t: text, r: result, c: css class, p: percent}
    log: function (o) {
      var t = esc(o.t || '');
      if (o.r) {
        var pad = 52 - (o.t || '').length, d = ''; while (pad-- > 0) d += '.';
        add('<span class="mute">&gt;</span> ' + t + ' <span class="mute">' + d + '</span> <span class="' + (o.c || 'ok') + '">' + esc(o.r) + '</span>');
      } else {
        add('<span class="' + (o.c || '') + '">' + t + '</span>');
      }
    },
    session: function (signedIn) {
      if (!signedIn && !signinShown) { signinShown = true; document.getElementById('signin').className = 'signin show'; }
    },
    done: function (signedIn) {
      if (signedIn) {
        add('<span class="ok">&gt; signed in. press play.</span>  <span class="mute">sign-in options any time: &#8679;&#8984;L</span>');
        setTimeout(function () { post('skip'); }, 1800);
      } else {
        add('<span class="warn">&gt; not signed in: pick a method above</span>');
        window.cp.session(false);
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
