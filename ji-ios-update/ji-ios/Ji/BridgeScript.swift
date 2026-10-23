import Foundation

/// 注入到网页里的脚本：把网页里 iOS 不支持 / 不好用的能力接到原生
enum BridgeScript {

    // 在网页脚本之前执行
    static let start = #"""
(function () {
  if (window.__JI_NATIVE__) return;
  window.__JI_NATIVE__ = true;
  document.documentElement.classList.add('native');

  var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ji;
  function post(m) { try { H.postMessage(m); } catch (e) {} }
  window.__jiPost = post;

  var seq = 0, pend = {};
  window.__jiResolve = function (id, v) { var f = pend[id]; delete pend[id]; if (f) f(v); };

  /* 1) 数据保险：localStorage 为空时，从原生备份文件恢复 */
  try {
    var b = window.__JI_BACKUP__;
    if (b && localStorage.length === 0) { for (var k in b) { localStorage.setItem(k, b[k]); } }
  } catch (e) {}
  window.__JI_BACKUP__ = null;

  /* 2) 每次写入后，把 localStorage 镜像到原生文件（防抖；绝不用空数据覆盖备份） */
  var timer = null;
  function snapshot() {
    var o = {};
    for (var i = 0; i < localStorage.length; i++) { var key = localStorage.key(i); o[key] = localStorage.getItem(key); }
    return o;
  }
  function flush() {
    if (timer) { clearTimeout(timer); timer = null; }
    try { var s = snapshot(); if (Object.keys(s).length) post({ cmd: 'persist', data: JSON.stringify(s) }); } catch (e) {}
  }
  function later() { if (timer) clearTimeout(timer); timer = setTimeout(flush, 1200); }
  var SP = Storage.prototype, _set = SP.setItem, _rm = SP.removeItem, _clr = SP.clear;
  SP.setItem = function (k, v) { _set.call(this, k, v); if (this === window.localStorage) later(); };
  SP.removeItem = function (k) { _rm.call(this, k); if (this === window.localStorage) later(); };
  SP.clear = function () { _clr.call(this); };
  document.addEventListener('visibilitychange', function () { if (document.hidden) flush(); });
  window.addEventListener('pagehide', flush);
  setTimeout(later, 3000);

  /* 3) 触感：网页里已有的 navigator.vibrate 调用 -> 系统触感引擎 */
  navigator.vibrate = function () { post({ cmd: 'haptic', style: 'light' }); return true; };
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest && e.target.closest('.nav-tab,.travel-tab,.cat-btn,.filter-btn,.type-option');
    if (t) post({ cmd: 'haptic', style: 'selection' });
  }, true);

  /* 4) 通知：Notification 在 WKWebView 里不存在，换成原生本地通知 */
  var perm = 'default';
  function N() { /* 真正的提醒由原生按时间排期发出，这里不需要再弹 */ }
  Object.defineProperty(N, 'permission', { get: function () { return perm; } });
  N.requestPermission = function (cb) {
    return new Promise(function (resolve) {
      var id = ++seq;
      pend[id] = function (p) { perm = p; if (cb) cb(p); resolve(p); };
      post({ cmd: 'notifyAuth', id: id });
    });
  };
  window.Notification = N;
  window.__jiPerm = function (p) {
    perm = p;
    try { if (window.updateNotifBanner) window.updateNotifBanner(); } catch (e) {}
    try { if (window.__jiSync) window.__jiSync(); } catch (e) {}
  };

  /* 5) 分享 / 下载：统一走系统分享面板（可存到「文件」、存图片、发给他人） */
  function toB64(blob) {
    return new Promise(function (res, rej) {
      var r = new FileReader();
      r.onload = function () { var s = String(r.result); res(s.slice(s.indexOf(',') + 1)); };
      r.onerror = rej;
      r.readAsDataURL(blob);
    });
  }
  function nativeShare(name, blob, text) {
    return new Promise(function (resolve) {
      var id = ++seq;
      pend[id] = function () { resolve(); };
      if (blob) {
        toB64(blob).then(function (b64) { post({ cmd: 'share', id: id, name: name, b64: b64 }); }, function () { resolve(); });
      } else {
        post({ cmd: 'share', id: id, text: text || '' });
      }
    });
  }
  Object.defineProperty(navigator, 'canShare', { value: function () { return true; }, configurable: true });
  Object.defineProperty(navigator, 'share', {
    value: function (d) {
      d = d || {};
      var f = d.files && d.files[0];
      if (f) return nativeShare(f.name, f);
      return nativeShare('', null, [d.title, d.text, d.url].filter(Boolean).join('\n'));
    },
    configurable: true
  });
  function intercept(a) {
    var href = a.href || '';
    if (!a.hasAttribute('download') || !/^(blob:|data:)/.test(href)) return false;
    var name = a.getAttribute('download') || 'file';
    fetch(href).then(function (r) { return r.blob(); }).then(function (bl) { nativeShare(name, bl); });
    return true;
  }
  var _click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () { if (intercept(this)) return; return _click.call(this); };
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest && e.target.closest('a[download]');
    if (a && intercept(a)) e.preventDefault();
  }, true);

  /* 5b) 照片：存成文件，网页里只保存 ji://app/photo/<id>.jpg 这样的短引用 */
  function hash(str) {
    var h1 = 0xdeadbeef, h2 = 0x41c6ce57;
    for (var i = 0; i < str.length; i++) {
      var ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761); h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return ('00000000' + (h2 >>> 0).toString(16)).slice(-8) + ('00000000' + (h1 >>> 0).toString(16)).slice(-8) + str.length.toString(16);
  }
  var PHOTO_RE = /^data:image\/(jpeg|png|webp);base64,/;
  function putPhoto(pid, dataUrl) {
    return new Promise(function (resolve) {
      var id = ++seq, done = false;
      function fin(v) { if (done) return; done = true; delete pend[id]; resolve(v === 'ok'); }
      pend[id] = fin;
      setTimeout(function () { fin('timeout'); }, 15000);
      post({ cmd: 'photoSave', id: id, pid: pid, b64: dataUrl.slice(dataUrl.indexOf(',') + 1) });
    });
  }
  window.__jiPutPhoto = putPhoto;
  // 存照片；任何一步失败都退回原来的 data URL，照片绝不会丢
  window.__jiStorePhoto = function (u) {
    if (typeof u !== 'string' || !PHOTO_RE.test(u)) return Promise.resolve(u);
    var pid = hash(u);
    return putPhoto(pid, u).then(function (ok) { return ok ? 'ji://app/photo/' + pid + '.jpg' : u; });
  };

  /* 6) 安全区兜底：如果 env(safe-area-inset-*) 读到 0，就用原生给的数值 */
  window.__jiInsets = function (t, bt) {
    try {
      var p = document.createElement('div');
      p.style.cssText = 'position:fixed;visibility:hidden;padding-top:env(safe-area-inset-top,0px)';
      (document.body || document.documentElement).appendChild(p);
      var ok = parseFloat(getComputedStyle(p).paddingTop) > 0;
      p.parentNode.removeChild(p);
      if (!ok && t > 0) {
        var s = document.documentElement.style;
        s.setProperty('--safe-top', t + 'px');
        s.setProperty('--safe-bottom', bt + 'px');
      }
    } catch (e) {}
  };
})();
"""#

    // 网页脚本执行完之后：把预约列表同步成系统本地通知
    static let end = #"""
(function () {
  if (!window.__JI_NATIVE__ || window.__jiEnd) return;
  window.__jiEnd = true;

  function sync() {
    try {
      if (typeof reminders === 'undefined') return;
      var items = [];
      reminders.forEach(function (r) {
        if (r.completed || r.notified) return;
        var ts = r.alertTime || (new Date(r.date + 'T' + r.time).getTime() - (r.advance || 0) * 60000);
        if (!isFinite(ts)) return;
        items.push({
          id: String(r.id),
          title: r.title || '预约提醒',
          body: '提醒时间：' + r.time + (r.desc ? '\n' + r.desc : ''),
          ts: ts,
          repeat: r.repeat || 'none'
        });
      });
      window.__jiPost({ cmd: 'schedule', items: items });
    } catch (e) {}
  }
  window.__jiSync = sync;

  if (typeof saveReminders === 'function') {
    var orig = saveReminders;
    window.saveReminders = function () { var out = orig.apply(this, arguments); sync(); return out; };
  }
  setTimeout(sync, 1500);

  /* 照片迁移：把 localStorage 里残留的 base64 照片搬到文件里，然后重新载入一次 */
  var DATA_RE = /data:image\/(?:jpeg|png|webp);base64,[A-Za-z0-9+\/=]+/g;
  function migrate() {
    var found = {}, any = false, i, v;
    for (i = 0; i < localStorage.length; i++) {
      v = localStorage.getItem(localStorage.key(i));
      if (v && v.indexOf('data:image/') >= 0) {
        (v.match(DATA_RE) || []).forEach(function (u) { found[u] = 1; any = true; });
      }
    }
    if (!any) return;
    try { if (window.showToast) showToast('正在整理照片…'); } catch (e) {}
    var map = {}, n = 0;
    Object.keys(found).reduce(function (p, u) {
      return p.then(function () {
        return window.__jiStorePhoto(u).then(function (r) { if (r !== u) { map[u] = r; n++; } });
      });
    }, Promise.resolve()).then(function () {
      if (!n) return;
      for (var j = 0; j < localStorage.length; j++) {          // 重新读取最新内容再替换，期间的修改不会丢
        var k = localStorage.key(j), val = localStorage.getItem(k);
        if (val && val.indexOf('data:image/') >= 0) {
          var nv = val.replace(DATA_RE, function (m) { return map[m] || m; });
          if (nv !== val) localStorage.setItem(k, nv);
        }
      }
      location.reload();
    });
  }
  setTimeout(migrate, 800);

  /* 清理不再被引用的照片文件 */
  setTimeout(function () {
    try {
      var keep = {}, i, v, m, re;
      for (i = 0; i < localStorage.length; i++) {
        v = localStorage.getItem(localStorage.key(i)) || '';
        re = /ji:\/\/app\/photo\/([0-9a-f]+)\.jpg/g;
        while ((m = re.exec(v))) keep[m[1]] = 1;
      }
      var ids = Object.keys(keep);
      if (ids.length) window.__jiPost({ cmd: 'photoGC', keep: ids });
    } catch (e) {}
  }, 20000);
})();
"""#
}
