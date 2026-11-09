/* MV2 event page: updating the signed extension installs its click listener on
   documents that are already open. No reload, navigation or app-open here. */
'use strict';
browser.runtime.onInstalled.addListener(function () {
  browser.tabs.query({}).then(function (tabs) {
    tabs.forEach(function (tab) {
      if (typeof tab.id !== 'number' || !/^https?:\/\//i.test(tab.url || '')) return;
      browser.tabs.executeScript(tab.id, {
        file: '/handoff.js', runAt: 'document_idle', allFrames: false
      }).catch(function () {
        // Browser-owned/restricted pages refuse script injection. Leave them alone.
      });
    });
  }).catch(function () {});
});
