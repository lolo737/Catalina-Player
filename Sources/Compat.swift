import Foundation

/// Small, self-written polyfills for JavaScript library functions that Safari 15.6
/// (Catalina's engine) lacks but newer sites assume. Injected before any page script runs.
///
/// What this can and can't do:
///  - It can add missing *functions* (Object.groupBy, Array.prototype.toSorted, …).
///  - It can't add missing *syntax* (regex lookbehind, class static blocks): code that uses
///    those fails to parse before anything can help it. The diagnostics log tells the two apart.
///  - It touches nothing to do with sign-in checks, copy protection or Spotify's own code.
///
/// Every polyfill only fills a gap: if the engine already has the function, it's left alone.
/// Turn off with:  defaults write io.github.lolo737.catalinaplayer DisableCompatShims -bool true
enum Compat {
    static var enabled: Bool { !UserDefaults.standard.bool(forKey: "DisableCompatShims") }

    static let shim = #"""
    (function () {
      var added = [];
      function def(obj, name, fn, label) {
        if (!obj || typeof obj[name] !== 'undefined') return;
        try {
          Object.defineProperty(obj, name, { value: fn, writable: true, configurable: true, enumerable: false });
          added.push(label);
        } catch (e) {}
      }
      function toLen(n) { n = Number(n); return n > 0 ? Math.min(Math.floor(n), 9007199254740991) : 0; }
      function toInt(n) { n = Number(n); return n !== n ? 0 : (n < 0 ? Math.ceil(n) : Math.floor(n)); }
      var AP = Array.prototype;

      // ES2023 change-array-by-copy (Safari 16)
      def(AP, 'toReversed', function () { return AP.slice.call(this).reverse(); }, 'Array.toReversed');
      def(AP, 'toSorted', function (cmp) {
        if (cmp !== undefined && typeof cmp !== 'function') throw new TypeError('The comparison function must be either a function or undefined');
        return AP.slice.call(this).sort(cmp);
      }, 'Array.toSorted');
      def(AP, 'toSpliced', function (start, skip) {
        var copy = AP.slice.call(this);
        AP.splice.apply(copy, arguments.length === 0 ? [] : arguments.length === 1 ? [start] : AP.slice.call(arguments));
        return copy;
      }, 'Array.toSpliced');
      def(AP, 'with', function (index, value) {
        var len = toLen(this.length), rel = toInt(index), i = rel >= 0 ? rel : len + rel;
        if (i < 0 || i >= len) throw new RangeError('Invalid index : ' + index);
        var copy = AP.slice.call(this); copy[i] = value; return copy;
      }, 'Array.with');

      // findLast / findLastIndex (Safari 15.4, present on 15.6; kept for older builds)
      def(AP, 'findLast', function (fn, thisArg) {
        for (var i = toLen(this.length) - 1; i >= 0; i--) if (fn.call(thisArg, this[i], i, this)) return this[i];
        return undefined;
      }, 'Array.findLast');
      def(AP, 'findLastIndex', function (fn, thisArg) {
        for (var i = toLen(this.length) - 1; i >= 0; i--) if (fn.call(thisArg, this[i], i, this)) return i;
        return -1;
      }, 'Array.findLastIndex');

      // Object.groupBy / Map.groupBy (Safari 17.4)
      def(Object, 'groupBy', function (items, fn) {
        var out = Object.create(null), i = 0;
        for (var it = items[Symbol.iterator](), s = it.next(); !s.done; s = it.next(), i++) {
          var k = fn(s.value, i);
          k = typeof k === 'symbol' ? k : String(k);
          (out[k] || (out[k] = [])).push(s.value);
        }
        return out;
      }, 'Object.groupBy');
      if (typeof Map !== 'undefined') def(Map, 'groupBy', function (items, fn) {
        var out = new Map(), i = 0;
        for (var it = items[Symbol.iterator](), s = it.next(); !s.done; s = it.next(), i++) {
          var k = fn(s.value, i);
          if (k === 0) k = 0;   // -0 becomes +0, like the spec
          if (!out.has(k)) out.set(k, []);
          out.get(k).push(s.value);
        }
        return out;
      }, 'Map.groupBy');

      // Promise.withResolvers (Safari 17.4)
      def(Promise, 'withResolvers', function () {
        var r = {};
        r.promise = new this(function (res, rej) { r.resolve = res; r.reject = rej; });
        return r;
      }, 'Promise.withResolvers');

      // Array.fromAsync (Safari 16.4)
      def(Array, 'fromAsync', function (items, mapFn, thisArg) {
        var C = this;
        return (async function () {
          var out = [], i = 0;
          if (items != null && typeof items[Symbol.asyncIterator] === 'function') {
            for await (var v of items) { out.push(mapFn ? await mapFn.call(thisArg, v, i) : v); i++; }
          } else {
            for (var w of (items[Symbol.iterator] ? items : AP.slice.call(items))) {
              var x = await w; out.push(mapFn ? await mapFn.call(thisArg, x, i) : x); i++;
            }
          }
          return C === Array || typeof C !== 'function' ? out : C.from(out);
        })();
      }, 'Array.fromAsync');

      // String well-formedness (Safari 16.4)
      def(String.prototype, 'isWellFormed', function () {
        return !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(^|[^\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(String(this));
      }, 'String.isWellFormed');
      def(String.prototype, 'toWellFormed', function () {
        return String(this).replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|([^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]/g,
          function (m, before) { return before !== undefined ? before + '�' : '�'; });
      }, 'String.toWellFormed');

      // Set methods (Safari 17)
      if (typeof Set !== 'undefined') {
        var SP = Set.prototype;
        function other(o) {
          if (o == null || typeof o.has !== 'function' || typeof o.keys !== 'function') throw new TypeError('Set method argument must be set-like');
          return o;
        }
        function keys(o) { var a = [], it = o.keys(), s; while (!(s = it.next()).done) a.push(s.value); return a; }
        def(SP, 'union', function (o) { var r = new Set(this); keys(other(o)).forEach(function (v) { r.add(v); }); return r; }, 'Set.union');
        def(SP, 'intersection', function (o) { o = other(o); var r = new Set(); this.forEach(function (v) { if (o.has(v)) r.add(v); }); return r; }, 'Set.intersection');
        def(SP, 'difference', function (o) { o = other(o); var r = new Set(); this.forEach(function (v) { if (!o.has(v)) r.add(v); }); return r; }, 'Set.difference');
        def(SP, 'symmetricDifference', function (o) {
          var self = this, r = new Set(this);
          keys(other(o)).forEach(function (v) { if (self.has(v)) r.delete(v); else r.add(v); });
          return r;
        }, 'Set.symmetricDifference');
        def(SP, 'isSubsetOf', function (o) { o = other(o); var ok = true; this.forEach(function (v) { if (!o.has(v)) ok = false; }); return ok; }, 'Set.isSubsetOf');
        def(SP, 'isSupersetOf', function (o) { var self = this; return keys(other(o)).every(function (v) { return self.has(v); }); }, 'Set.isSupersetOf');
        def(SP, 'isDisjointFrom', function (o) { o = other(o); var ok = true; this.forEach(function (v) { if (o.has(v)) ok = false; }); return ok; }, 'Set.isDisjointFrom');
      }

      // AbortSignal.timeout (Safari 16) and AbortSignal.any (Safari 17.4)
      if (typeof AbortSignal !== 'undefined' && typeof AbortController !== 'undefined') {
        def(AbortSignal, 'timeout', function (ms) {
          var c = new AbortController();
          setTimeout(function () {
            var err; try { err = new DOMException('The operation timed out.', 'TimeoutError'); } catch (e) { err = new Error('TimeoutError'); }
            c.abort(err);
          }, ms);
          return c.signal;
        }, 'AbortSignal.timeout');
        def(AbortSignal, 'any', function (signals) {
          var c = new AbortController();
          for (var i = 0; i < signals.length; i++) {
            if (signals[i].aborted) { c.abort(signals[i].reason); return c.signal; }
          }
          for (var j = 0; j < signals.length; j++) {
            (function (s) { s.addEventListener('abort', function () { if (!c.signal.aborted) c.abort(s.reason); }, { once: true }); })(signals[j]);
          }
          return c.signal;
        }, 'AbortSignal.any');
      }

      // Element.checkVisibility (Safari 17.4)
      if (typeof Element !== 'undefined') def(Element.prototype, 'checkVisibility', function (opts) {
        if (!this.isConnected) return false;
        for (var el = this; el && el.nodeType === 1; el = el.parentElement) {
          var cs = getComputedStyle(el);
          if (cs.display === 'none') return false;
          if (opts && (opts.opacityProperty || opts.checkOpacity) && cs.opacity === '0') return false;
        }
        if (opts && (opts.visibilityProperty || opts.checkVisibilityCSS) && getComputedStyle(this).visibility !== 'visible') return false;
        return true;
      }, 'Element.checkVisibility');

      try { window.__catalinaCompat = added; } catch (e) {}
      if (added.length) {
        try { window.webkit.messageHandlers.catalina.postMessage({ type: 'compat', added: added, href: location.host + location.pathname }); } catch (e) {}
      }
    })();
    """#
}

extension String {
    func ifEmpty(_ fallback: String) -> String { return isEmpty ? fallback : self }
}
