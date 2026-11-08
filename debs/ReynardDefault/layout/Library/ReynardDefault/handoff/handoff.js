/* ReynardDefault: 把网页里点到的非网页链接交给系统 App。
   Gecko 对未知协议的内容点击既不发 OnLoadRequest 也不发 OnPreNavigation，
   所以在页面里直接截住点击，再用 runtime.sendMessage 报给宿主。 */
(function () {
  if (window.__rdHandoffInstalled) return;
  window.__rdHandoffInstalled = true;

  var INTERNAL = {
    http: 1, https: 1, about: 1, data: 1, blob: 1, javascript: 1,
    'moz-extension': 1, jar: 1, 'view-source': 1, file: 1, resource: 1,
    wyciwyg: 1, ws: 1, wss: 1, ftp: 1
  };

  function schemeOf(href) {
    try {
      return (new URL(href, document.baseURI).protocol || '').replace(':', '').toLowerCase();
    } catch (e) {
      var m = /^([a-z][a-z0-9+.\-]*):/i.exec(href || '');
      return m ? m[1].toLowerCase() : '';
    }
  }

  // Pages like t.me advertise their app link in <meta property="al:ios:url">.
  // Under the Android user agent their button is a plain https link, so fall back
  // to the advertised app URL instead of letting the page reload itself.
  function advertisedAppURL() {
    var meta = document.querySelector('meta[property="al:ios:url"], meta[property="twitter:app:url:iphone"]');
    var value = meta && meta.getAttribute('content');
    if (!value) return null;
    return INTERNAL[schemeOf(value)] ? null : value;
  }

  function debug(stage, extra) {
    try { browser.runtime.sendMessage({ rdDebug: stage, extra: extra || '' }); } catch (e) {}
  }

  function report(href) {
    try {
      browser.runtime.sendMessage({ rdHandoff: href });
    } catch (e) {}
  }

  debug('boot', location.href);
  try { document.title = 'RD:' + document.title; } catch (e) {}

  document.addEventListener('click', function (event) {
    if (event.rdHandled) return;
    var node = event.target;
    while (node && node.nodeName !== 'A') node = node.parentNode;
    var href = node && node.getAttribute && node.getAttribute('href');
    debug('click', (node ? node.nodeName : '-') + ' ' + (href || ''));
    if (!href) return;
    var scheme = schemeOf(href);
    if (scheme === 'http' || scheme === 'https') {
      var appURL = advertisedAppURL();
      if (!appURL) return;
      event.preventDefault();
      event.stopPropagation();
      report(appURL);
      return;
    }
    if (!scheme || INTERNAL[scheme]) return;
    event.preventDefault();
    event.stopPropagation();
    event.rdHandled = true;
    try { href = new URL(href, document.baseURI).href; } catch (e) {}
    report(href);
  }, true);
})();
