import Foundation
import WebKit

/// Owns the shared WebKit configuration: content blockers, YouTube ad script, Safespace autofill,
/// LBrowser's page helpers and (per profile) web extensions.
@Observable @MainActor
final class WebEngine {
    static let shared = WebEngine()
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    @ObservationIgnored let contentController = WKUserContentController()
    @ObservationIgnored private let privateContentController = WKUserContentController()
    @ObservationIgnored private var ruleLists: [WKContentRuleList] = []
    private(set) var isAdBlockEnabled = UserDefaults.standard.object(forKey: "adBlockEnabled") as? Bool ?? true
    private(set) var isAutofillEnabled = UserDefaults.standard.object(forKey: "safespaceAutofill") as? Bool ?? true
    private(set) var developerToolsEnabled = UserDefaults.standard.bool(forKey: "developerTools")

    init() {
        contentController.addScriptMessageHandler(
            SafespaceAutofill.shared, contentWorld: SafespaceAutofill.world, name: SafespaceAutofill.handlerName)
        for controller in [contentController, privateContentController] {
            controller.add(PageScripts.handler, contentWorld: PageScripts.world, name: PageScripts.handlerName)
            controller.addScriptMessageHandler(GeolocationBridge.handler, contentWorld: .page, name: GeolocationBridge.handlerName)
        }
        apply()
    }

    func setDeveloperTools(_ enabled: Bool) {
        developerToolsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "developerTools")
        for store in WindowManager.shared.openStores {
            store.orderedTabs.forEach { $0.existingWebView?.isInspectable = enabled }
        }
    }

    @ObservationIgnored private var preparing: Task<Void, Never>?

    /// Compiles the content blockers once, however many windows ask.
    func prepare() async {
        if preparing == nil { preparing = Task { await compileRules() } }
        await preparing?.value
    }

    private func compileRules() async {
        let lists = [("lb-network", AdRules.networkJSON), ("lb-cosmetic", AdRules.cosmeticJSON)]
        for (identifier, json) in lists {
            do {
                let list: WKContentRuleList? = try await WKContentRuleListStore.default()
                    .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
                if let list { ruleLists.append(list) }
            } catch {
                NSLog("LBrowser: failed to compile \(identifier): \(error)")
            }
        }
        apply()
    }

    func setAdBlock(_ enabled: Bool) {
        isAdBlockEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "adBlockEnabled")
        apply()
    }

    func setAutofill(_ enabled: Bool) {
        isAutofillEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "safespaceAutofill")
        apply()
    }

    private func apply() {
        contentController.removeAllContentRuleLists()
        contentController.removeAllUserScripts()
        if isAutofillEnabled { contentController.addUserScript(SafespaceAutofill.shared.userScript) }
        privateContentController.removeAllContentRuleLists()
        privateContentController.removeAllUserScripts()
        for controller in [contentController, privateContentController] {
            controller.addUserScript(PageScripts.userScript)
            controller.addUserScript(GeolocationBridge.userScript)
        }
        guard isAdBlockEnabled else { return }
        for controller in [contentController, privateContentController] {
            ruleLists.forEach(controller.add)
            controller.addUserScript(WKUserScript(
                source: AdRules.youtubeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    func makeConfiguration(dataStore: WKWebsiteDataStore, profileID: String = Profile.defaultID) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = dataStore.isPersistent ? contentController : privateContentController
        config.websiteDataStore = dataStore
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        if developerToolsEnabled, config.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            // Adds "Inspect Element" to the page's context menu.
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        if dataStore.isPersistent { Extensions.shared.attach(to: config, profileID: profileID) }
        return config
    }
}

enum AdRules {
    static let adDomains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagservices.com",
        "adservice.google.com", "google-analytics.com", "2mdn.net", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "amazon-adsystem.com",
        "scorecardresearch.com", "moatads.com", "pubmatic.com", "rubiconproject.com", "openx.net",
        "casalemedia.com", "advertising.com", "adform.net", "smartadserver.com", "quantserve.com",
        "zedo.com", "yieldmo.com", "sharethrough.com", "teads.tv", "33across.com", "media.net",
        "bidswitch.net", "contextweb.com", "indexww.com", "lijit.com", "sovrn.com", "mathtag.com",
        "rlcdn.com", "demdex.net", "everesttech.net", "adsafeprotected.com", "doubleverify.com",
        "serving-sys.com", "flashtalking.com", "adcolony.com", "popads.net", "popcash.net",
        "propellerads.com", "exoclick.com", "trafficjunky.net", "juicyads.com", "revcontent.com",
        "mgid.com", "zergnet.com", "adroll.com", "hotjar.com", "mouseflow.com", "crazyegg.com",
        "ads.twitter.com", "analytics.twitter.com", "ads.linkedin.com", "ads.yahoo.com",
        "bat.bing.com", "imrworldwide.com", "adtechus.com", "yieldlab.net", "adition.com",
        "smaato.net", "inmobi.com", "unityads.unity3d.com", "ads.reddit.com", "adsymptotic.com",
    ]

    /// Path-level blocks for YouTube ad/tracking endpoints (WebKit regex has no alternation).
    static let youtubePaths = ["pagead/", "api/stats/ads", "ptracking", "get_midroll_"]

    static var networkJSON: String {
        var rules: [[String: Any]] = adDomains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return ["trigger": ["url-filter": "^[a-z]+://([^/]+\\.)?\(escaped)[:/]"], "action": ["type": "block"]]
        }
        rules += youtubePaths.map { path in
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?youtube\\.com/\(path)"], "action": ["type": "block"]]
        }
        return encode(rules)
    }

    static var cosmeticJSON: String {
        let selectors = [
            "ins.adsbygoogle", ".adsbygoogle", "[id^=\"div-gpt-ad\"]", "[id^=\"google_ads_iframe\"]",
            "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication.com\"]", "[data-ad-slot]",
            "amp-ad", ".ad-banner", "#ad-banner", ".adsbox", ".taboola", "#taboola-below-article-thumbnails",
            ".OUTBRAIN", "[data-google-query-id]",
        ]
        let rule: [String: Any] = [
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
        ]
        return encode([rule])
    }

    private static func encode(_ rules: [[String: Any]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    /// Strips ads from YouTube's player data before the player sees them, hides ad slots,
    /// and fast-forwards/skips any ad that still slips through.
    static let youtubeScript = #"""
    (() => {
      if (window.__lbYouTube) return;
      window.__lbYouTube = true;
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return;

      const AD_KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
      const prune = (o) => {
        if (!o || typeof o !== 'object') return o;
        try {
          for (const k of AD_KEYS) if (k in o) delete o[k];
          if (o.playerResponse) prune(o.playerResponse);
          if (Array.isArray(o)) for (const x of o) if (x && x.playerResponse) prune(x.playerResponse);
        } catch (e) {}
        return o;
      };

      const parse = JSON.parse;
      JSON.parse = function (...args) { return prune(parse.apply(this, args)); };
      const json = Response.prototype.json;
      Response.prototype.json = function (...args) { return json.apply(this, args).then(prune); };
      let initial;
      try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
          configurable: true, get: () => initial, set: (v) => { initial = prune(v); }
        });
      } catch (e) {}

      const css = [
        `#masthead-ad, ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-banner-promo-renderer,
         ytd-statement-banner-renderer, ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer,
         ytd-display-ad-renderer, ytd-compact-promoted-video-renderer, ytd-search-pyv-renderer,
         ytd-player-legacy-desktop-watch-ads-renderer, ytd-merch-shelf-renderer, #player-ads,
         ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"],
         .ytp-ad-overlay-container, .ytp-ad-image-overlay, ytd-enforcement-message-view-model,
         ad-slot-renderer, ytm-promoted-sparkles-web-renderer { display: none !important; }`,
        `ytd-rich-item-renderer:has(ytd-ad-slot-renderer), ytd-rich-section-renderer:has(ytd-statement-banner-renderer),
         tp-yt-paper-dialog:has(ytd-enforcement-message-view-model) { display: none !important; }`
      ].join('\n');
      const addStyle = () => {
        const style = document.createElement('style');
        style.textContent = css;
        (document.head || document.documentElement).appendChild(style);
      };
      if (document.documentElement) addStyle(); else document.addEventListener('DOMContentLoaded', addStyle);

      let mutedByUs = false, savedRate = null;
      const tick = () => {
        const player = document.querySelector('#movie_player, .html5-video-player');
        if (!player) return;
        const video = player.querySelector('video');
        const inAd = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
        if (inAd && video) {
          if (!video.muted) { video.muted = true; mutedByUs = true; }
          if (savedRate === null) savedRate = video.playbackRate;
          video.playbackRate = 16;
          if (isFinite(video.duration) && video.duration > 0) { try { video.currentTime = video.duration; } catch (e) {} }
          player.querySelectorAll('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button, [id^="skip-button"] button')
            .forEach((b) => b.click());
        } else if (video) {
          if (mutedByUs) { video.muted = false; mutedByUs = false; }
          if (savedRate !== null) { video.playbackRate = savedRate; savedRate = null; }
        }
        const nag = document.querySelector('ytd-enforcement-message-view-model');
        if (nag) {
          const dialog = nag.closest('tp-yt-paper-dialog');
          if (dialog) dialog.remove();
          const backdrop = document.querySelector('tp-yt-iron-overlay-backdrop');
          if (backdrop) backdrop.remove();
          if (video && video.paused) video.play().catch(() => {});
        }
      };
      setInterval(tick, 250);
    })();
    """#
}
