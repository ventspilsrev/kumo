// Runtime prelude for Paperback 0.8 extensions.
//
// This file is loaded into a fresh, empty JavaScript context BEFORE the
// extension bundle. It builds the global `App` object the extensions expect
// (API shape taken from the public @paperback/types 0.8.7 declarations and
// from what the real bundles call).
//
// The same file is used in two places, so what the PC harness proves is what
// the iPad runs:
//   - harness/run.js   : Node `vm` context, host bridge written in Node
//   - the iOS app      : JavaScriptCore context, host bridge written in Swift
//
// The ONLY way out of the context is the `__host` object. The extension has
// no file access, no network access and no timers except through it.
//
// __host contract (all values are plain JSON-friendly data):
//   log(level, message)
//   setTimeout(fn, ms) -> id          clearTimeout(id)
//   userAgent() -> string
//   fetch(request, resolve, reject)   request  = {url, method, headers, body, timeoutMs}
//                                     resolve({status, headers, bytes: ArrayBuffer, text})
//   cookiesGet() -> [{name,value,domain,path,expires}]   (expires = ms or null)
//   cookieSet(cookie)                 cookieRemove(cookie)
//   stateGet(key) -> JSON string or null                 stateSet(key, jsonString)
//   event(name, payload)              e.g. "challenge" when a site wants verification
(function (global) {
  'use strict';
  var host = global.__host;

  // ---------------------------------------------------------------- globals
  // JavaScriptCore has none of these built in.

  function fmt(args) {
    return Array.prototype.map.call(args, function (a) {
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(' ');
  }
  global.console = {
    log: function () { host.log('info', fmt(arguments)); },
    info: function () { host.log('info', fmt(arguments)); },
    debug: function () { host.log('debug', fmt(arguments)); },
    warn: function () { host.log('warn', fmt(arguments)); },
    error: function () { host.log('error', fmt(arguments)); }
  };

  global.setTimeout = function (fn, ms) {
    var args = Array.prototype.slice.call(arguments, 2);
    return host.setTimeout(function () { fn.apply(null, args); }, Number(ms) || 0);
  };
  global.clearTimeout = function (id) { host.clearTimeout(id); };
  // setInterval is built on setTimeout so the host only needs one timer type.
  var intervals = {};
  var nextInterval = 1;
  global.setInterval = function (fn, ms) {
    var id = nextInterval++;
    (function tick() {
      intervals[id] = host.setTimeout(function () {
        if (!(id in intervals)) return;
        try { fn(); } finally { if (id in intervals) tick(); }
      }, Number(ms) || 0);
    })();
    return id;
  };
  global.clearInterval = function (id) {
    if (id in intervals) { host.clearTimeout(intervals[id]); delete intervals[id]; }
  };

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  global.btoa = function (input) {
    var s = String(input), out = '';
    for (var i = 0; i < s.length; i += 3) {
      var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
      if (a > 255 || b > 255 || c > 255) throw new Error('btoa: character out of range');
      var n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] +
        (i + 1 < s.length ? B64[(n >> 6) & 63] : '=') +
        (i + 2 < s.length ? B64[n & 63] : '=');
    }
    return out;
  };
  global.atob = function (input) {
    var s = String(input).replace(/[\t\n\f\r ]/g, '').replace(/=+$/, ''), out = '';
    var bits = 0, acc = 0;
    for (var i = 0; i < s.length; i++) {
      var v = B64.indexOf(s[i]);
      if (v < 0) throw new Error('atob: invalid character');
      acc = (acc << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); }
    }
    return out;
  };

  function TextEncoder() {}
  TextEncoder.prototype.encoding = 'utf-8';
  TextEncoder.prototype.encode = function (str) {
    str = str === undefined ? '' : String(str);
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var d = str.charCodeAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  };
  function TextDecoder(label) {
    var l = String(label || 'utf-8').toLowerCase();
    this.latin1 = (l === 'latin1' || l === 'iso-8859-1' || l === 'ascii' || l === 'windows-1252');
    this.encoding = this.latin1 ? 'windows-1252' : 'utf-8';
  }
  TextDecoder.prototype.decode = function (input) {
    if (input === undefined) return '';
    var b = input instanceof Uint8Array ? input
      : new Uint8Array(input.buffer ? input.buffer : input, input.byteOffset || 0, input.byteLength);
    var parts = [], chunk = [];
    function push(code) {
      if (code > 0xffff) { code -= 0x10000; chunk.push(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff)); }
      else chunk.push(code);
      if (chunk.length >= 8192) { parts.push(String.fromCharCode.apply(null, chunk)); chunk = []; }
    }
    for (var i = 0; i < b.length;) {
      var c = b[i++];
      if (this.latin1 || c < 0x80) { push(c); continue; }
      var need = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : c >= 0xc0 ? 1 : -1;
      if (need < 0 || i + need > b.length) { push(0xfffd); continue; }
      var code = c & (0x3f >> need), ok = true;
      for (var k = 0; k < need; k++) {
        var n = b[i + k];
        if ((n & 0xc0) !== 0x80) { ok = false; break; }
        code = (code << 6) | (n & 63);
      }
      if (!ok) { push(0xfffd); continue; }
      i += need;
      push(code);
    }
    parts.push(String.fromCharCode.apply(null, chunk));
    return parts.join('');
  };
  global.TextEncoder = TextEncoder;
  global.TextDecoder = TextDecoder;

  // ------------------------------------------------------------------- App
  var App = {};
  global.App = App;

  // Plain data constructors. In Paperback these return native objects; the
  // extensions only read back the fields they set, so a copy is enough.
  function copy(info) { var o = {}; for (var k in info) o[k] = info[k]; return o; }
  [
    'SourceManga', 'MangaInfo', 'PartialSourceManga', 'Chapter', 'ChapterDetails',
    'Tag', 'TagSection', 'SearchField', 'Cookie', 'IconText', 'MangaUpdates',
    // Settings UI rows ("DUI"). The app renders these; here they are data + callbacks.
    'DUIBinding', 'DUIForm', 'DUISection', 'DUIButton', 'DUIHeader', 'DUIInputField',
    'DUILabel', 'DUILink', 'DUIMultilineLabel', 'DUINavigationButton', 'DUIOAuthButton',
    'DUISecureInputField', 'DUISelect', 'DUIStepper', 'DUISwitch'
  ].forEach(function (name) {
    App['create' + name] = function (info) { var o = copy(info); o.__type = name; return o; };
  });
  App.createHomeSection = function (info) {
    var o = copy(info); if (!o.items) o.items = []; return o;
  };
  App.createPagedResults = function (info) {
    var o = copy(info || {}); if (!o.results) o.results = []; return o;
  };
  App.createRequest = function (info) {
    var o = copy(info); if (!o.headers) o.headers = {}; if (!o.cookies) o.cookies = []; return o;
  };
  // Raw bytes are a Uint8Array on our side, so ByteArray and RawData are the
  // same object. This matters: ComixTo decrypts images IN PLACE through
  // createByteArray(response.rawData) and never assigns the result back.
  App.createRawData = function (info) { return info.byteArray; };
  App.createByteArray = function (raw) { return raw; };

  // ---- cookies
  function cookieStore() {
    return {
      getAllCookies: function () {
        return host.cookiesGet().map(function (c) {
          return { name: c.name, value: c.value, domain: c.domain, path: c.path || '/',
            expires: c.expires == null ? undefined : new Date(c.expires) };
        });
      },
      addCookie: function (c) {
        host.cookieSet({ name: c.name, value: c.value, domain: c.domain, path: c.path || '/',
          expires: c.expires ? new Date(c.expires).getTime() : null });
      },
      removeCookie: function (c) {
        host.cookieRemove({ name: c.name, domain: c.domain, path: c.path || '/' });
      }
    };
  }

  // ---- state (per-source settings storage). Values are stored as JSON.
  App.createSourceStateManager = function () {
    function make(prefix) {
      return {
        store: function (key, value) {
          host.stateSet(prefix + key, value === undefined || value === null ? null : JSON.stringify(value));
          return Promise.resolve();
        },
        retrieve: function (key) {
          var raw = host.stateGet(prefix + key);
          return Promise.resolve(raw == null ? null : JSON.parse(raw));
        }
      };
    }
    var m = make('state:');
    m.keychain = make('secure:');
    return m;
  };

  // ---- network
  function encodeBody(data, headers) {
    if (data === undefined || data === null) return null;
    if (typeof data === 'string') return data;
    if (data instanceof Uint8Array) return data;
    var ct = '';
    for (var k in headers) if (k.toLowerCase() === 'content-type') ct = String(headers[k]).toLowerCase();
    if (ct.indexOf('json') >= 0) return JSON.stringify(data);
    // Objects default to a form-encoded body. (Assumption, not confirmed
    // against Paperback; neither of the two studied sources sends an object.)
    return Object.keys(data).map(function (k) {
      return encodeURIComponent(k) + '=' + encodeURIComponent(data[k]);
    }).join('&');
  }

  App.createRequestManager = function (info) {
    info = info || {};
    var rps = info.requestsPerSecond > 0 ? info.requestsPerSecond : 4;
    var timeoutMs = info.requestTimeout > 0 ? info.requestTimeout : 20000;
    var gap = 1000 / rps;
    var nextSlot = 0;

    // Politeness: requests from one manager are spaced at least `gap` ms apart.
    function waitForSlot() {
      var now = Date.now();
      var at = Math.max(now, nextSlot);
      nextSlot = at + gap;
      if (at <= now) return Promise.resolve();
      return new Promise(function (resolve) { host.setTimeout(resolve, at - now); });
    }

    function send(request) {
      return new Promise(function (resolve, reject) {
        var headers = copy(request.headers || {});
        if (request.cookies && request.cookies.length) {
          var extra = request.cookies.map(function (c) { return c.name + '=' + c.value; }).join('; ');
          var key = 'Cookie';
          for (var k in headers) if (k.toLowerCase() === 'cookie') key = k;
          headers[key] = headers[key] ? headers[key] + '; ' + extra : extra;
        }
        var url = request.url + (request.param ? request.param : '');
        host.fetch({
          url: url,
          method: (request.method || 'GET').toUpperCase(),
          headers: headers,
          body: encodeBody(request.data, headers),
          timeoutMs: timeoutMs
        }, resolve, function (message) { reject(new Error(String(message))); });
      });
    }

    var manager = {
      requestsPerSecond: rps,
      requestTimeout: timeoutMs,
      interceptor: info.interceptor,
      cookieStore: cookieStore(),
      getDefaultUserAgent: function () { return Promise.resolve(host.userAgent()); },
      schedule: function (request, retry) {
        var attemptsLeft = Math.max(0, Number(retry) || 0);
        var intercepted;
        function attempt() {
          return waitForSlot().then(function () { return send(intercepted); }).catch(function (err) {
            // Only network-level failures are retried, never HTTP statuses.
            if (attemptsLeft-- > 0) return attempt();
            throw err;
          });
        }
        var before = info.interceptor && info.interceptor.interceptRequest
          ? Promise.resolve(info.interceptor.interceptRequest(request))
          : Promise.resolve(request);
        return before.then(function (req) {
          intercepted = req || request;
          return attempt();
        }).then(function (res) {
          var response = {
            data: res.text,
            rawData: new Uint8Array(res.bytes),
            status: res.status,
            headers: res.headers || {},
            request: intercepted
          };
          var mitigated = '';
          for (var k in response.headers) if (k.toLowerCase() === 'cf-mitigated') mitigated = String(response.headers[k]);
          if ((res.status === 403 || res.status === 503) &&
              (mitigated === 'challenge' || /<title>Just a moment|cf-chl-|challenge-platform/i.test(res.text || ''))) {
            host.event('challenge', { url: intercepted.url, status: res.status });
          }
          if (info.interceptor && info.interceptor.interceptResponse) {
            return Promise.resolve(info.interceptor.interceptResponse(response)).then(function (r) { return r || response; });
          }
          return response;
        });
      }
    };
    return manager;
  };

  // Images (ComixTo un-scrambling). Provided natively by the host later.
  App.createPBImage = function (info) {
    if (!host.imageDecode) throw new Error('PBImage is not available in this host yet');
    return host.imageDecode(info.data);
  };
  App.createPBCanvas = function () {
    if (!host.canvasCreate) throw new Error('PBCanvas is not available in this host yet');
    return host.canvasCreate();
  };

  // -------------------------------------------------------------- dispatcher
  // The host talks to a source only through __pb, with JSON in and JSON out,
  // so nothing from the extension ever leaks into the app as a live object.
  var instances = {};

  function plain(value) {
    // Dates become ISO strings (or null when the extension produced an invalid date).
    return JSON.parse(JSON.stringify(value === undefined ? null : value, function (key, v) {
      var raw = this[key];
      if (raw instanceof Date) return isNaN(raw.getTime()) ? null : raw.toISOString();
      if (typeof v === 'number' && !isFinite(v)) return null;
      return v;
    }));
  }

  global.__pb = {
    // Returns the source's own metadata object (`<Id>Info`) as JSON.
    info: function (id) {
      var all = global.Sources || {};
      if (!all[id]) throw new Error('Bundle does not contain source "' + id + '"');
      return JSON.stringify(plain(all[id + 'Info'] || null));
    },
    // Calls a method on the source. `onSection` is used by getHomePageSections.
    call: function (id, method, argsJSON, resolve, reject, onSection) {
      try {
        var all = global.Sources || {};
        if (!all[id]) throw new Error('Bundle does not contain source "' + id + '"');
        var src = instances[id] || (instances[id] = new all[id]({}));
        if (typeof src[method] !== 'function') throw new Error('Source does not support ' + method);
        var args = JSON.parse(argsJSON || '[]');
        if (method === 'getHomePageSections') {
          args = [function (section) { onSection(JSON.stringify(plain(section))); }];
        }
        Promise.resolve(src[method].apply(src, args)).then(function (result) {
          resolve(JSON.stringify(plain(result)));
        }, function (err) {
          reject(String((err && err.message) || err));
        });
      } catch (err) {
        reject(String((err && err.message) || err));
      }
    },
    // Fetches one page image THROUGH the source's request manager so its
    // interceptors run (referer header, un-scrambling, decryption).
    image: function (id, url, resolve, reject) {
      try {
        var src = instances[id] || (instances[id] = new global.Sources[id]({}));
        src.requestManager.schedule(App.createRequest({ url: url, method: 'GET' }), 1).then(function (res) {
          resolve({ status: res.status, headers: res.headers, bytes: res.rawData });
        }, function (err) { reject(String((err && err.message) || err)); });
      } catch (err) {
        reject(String((err && err.message) || err));
      }
    }
  };
})(this);
