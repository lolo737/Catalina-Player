import Foundation

/// Small pieces of JavaScript run inside the Spotify web player.
/// They only read what's on screen and press Spotify's own buttons: nothing is changed or blocked.
enum Scripts {

    /// Watches for Spotify saying it can't play here (usually copy-protection support),
    /// so the app can offer Firefox instead of leaving you staring at an error.
    static let watchForProblems = #"""
    (function () {
      var phrases = [
        "Playback of protected content is not enabled",
        "protected content",
        "browser doesn't support",
        "browser isn't supported",
        "This browser doesn't support"
      ];
      var sent = false;
      function check() {
        if (sent || !document.body) return;
        var body = document.body;
        var text = (typeof body.innerText === "string" ? body.innerText : body.textContent) || "";
        for (var i = 0; i < phrases.length; i++) {
          if (text.indexOf(phrases[i]) !== -1) {
            sent = true;
            window.webkit.messageHandlers.catalina.postMessage({ type: "problem", text: phrases[i] });
            return;
          }
        }
      }
      setInterval(check, 3000);
    })();
    """#

    /// What's playing right now, as JSON: title, artist, playing, and the page title as a fallback.
    static let nowPlaying = #"""
    (function () {
      function q(s) { return document.querySelector(s); }
      function text(el) { return el ? (el.textContent || "").trim() : ""; }
      var button = q('[data-testid="control-button-playpause"]');
      var label = button ? (button.getAttribute("aria-label") || "") : "";
      var media = Array.prototype.slice.call(document.querySelectorAll("video, audio"));
      var mediaPlaying = media.some(function (m) { return !m.paused && !m.ended; });
      return JSON.stringify({
        title: text(q('[data-testid="context-item-info-title"]')) || text(q('[data-testid="context-item-link"]')),
        artist: text(q('[data-testid="context-item-info-artist"]')) || text(q('[data-testid="context-item-info-subtitles"]')),
        playing: mediaPlaying || /pause/i.test(label),
        docTitle: document.title || ""
      });
    })()
    """#

    /// Presses Spotify's own player buttons. action: toggle, play, pause, next, prev.
    static func control(_ action: String) -> String {
        return #"""
        (function (action) {
          function q(s) { return document.querySelector(s); }
          var ids = { next: "control-button-skip-forward", prev: "control-button-skip-back" };
          var playpause = q('[data-testid="control-button-playpause"]');
          var media = Array.prototype.slice.call(document.querySelectorAll("video, audio"));
          var label = playpause ? (playpause.getAttribute("aria-label") || "") : "";
          var playing = media.some(function (m) { return !m.paused && !m.ended; }) || /pause/i.test(label);
          var target = null;
          if (action === "toggle") target = playpause;
          else if (action === "play") target = playing ? null : playpause;
          else if (action === "pause") target = playing ? playpause : null;
          else target = q('[data-testid="' + ids[action] + '"]');
          if (target) { target.click(); return true; }
          return false;
        })("\#(action)")
        """#
    }

    static func setZoom(_ zoom: Double) -> String {
        return "document.documentElement.style.zoom = '\(zoom)';"
    }
}
