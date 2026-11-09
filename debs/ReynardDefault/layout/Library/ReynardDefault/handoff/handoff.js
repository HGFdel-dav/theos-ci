/* ReynardDefault click bridge v2.
   It never opens an app during load, refresh, history, or background work.
   Only a trusted primary click on a non-web anchor reaches the bridge. */
(function () {
  'use strict';
  if (window.__rdHandoffV2Installed) return;
  window.__rdHandoffV2Installed = true;

  var INTERNAL = new Set([
    'http', 'https', 'about', 'data', 'blob', 'javascript', 'moz-extension',
    'jar', 'view-source', 'file', 'resource', 'wyciwyg', 'ws', 'wss', 'ftp',
    'intent', 'reynard', 'chrome', 'chrome-extension'
  ]);
  var BRIDGE = 'https://reynarddefault.invalid/.well-known/handoff/v2#';

  function clickedLink(event) {
    var path = typeof event.composedPath === 'function' ? event.composedPath() : [];
    for (var i = 0; i < path.length; i++) {
      var item = path[i];
      if (item && /^(a|area)$/i.test(item.nodeName || '') && item.getAttribute) return item;
    }
    var target = event.target;
    if (target && target.nodeType === 3) target = target.parentElement;
    return target && target.closest ? target.closest('a[href],area[href]') : null;
  }

  function requestID() {
    var bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, function (b) { return b.toString(16).padStart(2, '0'); }).join('');
  }

  document.addEventListener('click', function (event) {
    // No synthetic clicks, modifiers, secondary buttons, downloads, hidden pages,
    // or previously cancelled events. This is the user-click gate.
    if (event.isTrusted !== true || event.defaultPrevented || event.button !== 0 ||
        event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || document.hidden) return;

    var link = clickedLink(event);
    if (!link || link.hasAttribute('download')) return;
    var raw = link.getAttribute('href');
    if (!raw || raw.length > 16384 || /[\u0000-\u0020\u007f]/.test(raw)) return;

    var url;
    try { url = new URL(raw, document.baseURI); } catch (_) { return; }
    var scheme = url.protocol.slice(0, -1).toLowerCase();
    if (!scheme || INTERNAL.has(scheme)) return;

    var id;
    try { id = requestID(); } catch (_) { return; }
    var fragment = 'v=2&id=' + id + '&ts=' + Date.now() +
      '&a=' + encodeURIComponent(url.href) + '&h=';
    try {
      // One '#' only; the native parser validates every field and decodes once.
      location.href = BRIDGE + fragment;
      event.preventDefault();
      event.stopImmediatePropagation();
    } catch (_) {
      // If navigation assignment itself fails, the browser retains its normal path.
    }
  }, true);
})();
