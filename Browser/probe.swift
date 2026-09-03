// MiniBrowser (c) 2026 Trendzza. All rights reserved.
// Free forever, non-commercial — see LICENSE.
import WebKit
import Foundation
import Darwin

let store = WKWebsiteDataStore.default()

func makeConfig(turbo: Bool) -> WKWebViewConfiguration {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = store
    if turbo {
        let script = WKUserScript(source: """
        (() => {
          if (window.__miniTurbo) return; window.__miniTurbo = true;
          const style = document.createElement('style');
          style.textContent = 'img,iframe,video{content-visibility:auto;contain-intrinsic-size:auto 1px}';
          (document.head || document.documentElement).appendChild(style);
          const lazy = () => {
            for (const img of document.images) {
              if (img.loading !== 'lazy' && !img.complete && img.getBoundingClientRect().top > (innerHeight * 1.5)) {
                img.loading = 'lazy';
              }
            }
          };
          lazy();
          new MutationObserver(lazy).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        c.userContentController.addUserScript(script)
    }
    return c
}

let url = URL(string: "https://www.youtube.com")!
let probe = """
(() => {
  const n = performance.getEntriesByType('navigation')[0];
  const rts = performance.getEntriesByType('resource').length;
  return JSON.stringify({
    fetchStart: Math.round(n.fetchStart),
    domInteractive: Math.round(n.domInteractive),
    domContentLoaded: Math.round(n.domContentLoadedEventEnd),
    loadEvent: Math.round(n.loadEventEnd),
    resources: rts
  });
})()
"""

func measure(_ label: String, _ turbo: Bool) {
    let config = makeConfig(turbo: turbo)
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
    wv.load(URLRequest(url: url))
    let deadline = Date().addingTimeInterval(25)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if !wv.isLoading { break }
        if Date() > deadline { break }
    }
    let sem = DispatchSemaphore(value: 0)
    wv.evaluateJavaScript(probe) { res, _ in
        print("\(label):", res as? String ?? "n/a")
        sem.signal()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    _ = sem.wait(timeout: .now() + 1)
    wv.stopLoading()
}

print("=== A/B: YouTube home ===")
measure("TURBO OFF", false)
RunLoop.main.run(until: Date().addingTimeInterval(1))
measure("TURBO ON ", true)
exit(0)