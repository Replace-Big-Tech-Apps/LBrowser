import Foundation
import WebKit

/// LBrowser's own helpers inside every page, in an isolated JavaScript world the page can't see:
/// sound detection and muting, picture-in-picture, Reader extraction, translation and form autofill.
@MainActor
enum PageScripts {
    static let world = WKContentWorld.world(name: "lbrowser")
    static let handlerName = "lbrowser"
    static let handler = Handler()

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let tab = BrowserTab.owner(of: message.webView) else { return }
                if body["type"] as? String == "media", let playing = body["playing"] as? Bool {
                    tab.mediaReport(playing: playing, frame: message.frameInfo)
                }
            }
        }
    }

    /// Runs `body` (a JavaScript function body) in LBrowser's world of the tab's page.
    static func call(_ body: String, in tab: BrowserTab, arguments: [String: Any] = [:]) async -> Any? {
        guard let web = tab.existingWebView else { return nil }
        return try? await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
    }

    /// After a page loads: is it an article, and which language is it in?
    static func inspect(_ tab: BrowserTab) async {
        guard let info = await call("return window.__lbInspect ? window.__lbInspect() : null", in: tab) as? [String: Any] else { return }
        tab.readerAvailable = info["readerable"] as? Bool ?? false
        tab.pageLanguage = (info["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static let source = #"""
    (() => {
      if (window.__lbInstalled) return;
      window.__lbInstalled = true;
      const post = (msg) => { try { window.webkit.messageHandlers.lbrowser.postMessage(msg); } catch (e) {} };

      // MARK: Sound
      window.__lbMuted = false;
      let lastPlaying = false;
      const media = () => Array.from(document.querySelectorAll('video, audio'));
      const audible = (m) => !m.paused && !m.ended && !m.muted && m.volume > 0 && m.readyState > 2;
      const report = () => {
        const playing = media().some((m) => audible(m) || (window.__lbMuted && !m.paused && !m.ended && m.readyState > 2));
        if (playing !== lastPlaying) { lastPlaying = playing; post({ type: 'media', playing }); }
      };
      for (const ev of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
        document.addEventListener(ev, (e) => {
          if (window.__lbMuted && ev === 'play' && e.target && 'muted' in e.target) e.target.muted = true;
          setTimeout(report, 50);
        }, true);
      }
      window.__lbSetMuted = (muted) => {
        window.__lbMuted = muted;
        for (const m of media()) m.muted = muted;
        report();
      };

      // MARK: Picture in picture
      window.__lbPictureInPicture = () => {
        const videos = Array.from(document.querySelectorAll('video'));
        if (!videos.length) return false;
        if (document.pictureInPictureElement) { document.exitPictureInPicture(); return true; }
        const area = (v) => v.clientWidth * v.clientHeight;
        const video = videos.find((v) => !v.paused) || videos.sort((a, b) => area(b) - area(a))[0];
        video.disablePictureInPicture = false;
        if (video.requestPictureInPicture) { video.requestPictureInPicture().catch(() => {
          if (video.webkitSetPresentationMode) video.webkitSetPresentationMode('picture-in-picture');
        }); return true; }
        if (video.webkitSetPresentationMode) { video.webkitSetPresentationMode('picture-in-picture'); return true; }
        return false;
      };

      // MARK: Reader
      const SKIP = /comment|share|social|related|promo|sponsor|advert|\bad-|sidebar|footer|newsletter|subscribe|cookie|banner|nav|menu|breadcrumb|popup|modal/i;
      const paragraphs = () => Array.from(document.querySelectorAll('p')).filter((p) => p.innerText && p.innerText.trim().length > 60);
      window.__lbInspect = () => {
        const text = paragraphs().reduce((n, p) => n + p.innerText.trim().length, 0);
        return { readerable: text > 1200 && paragraphs().length >= 4, lang: (document.documentElement.lang || '').trim() };
      };
      window.__lbReader = () => {
        const scores = new Map();
        for (const p of paragraphs()) {
          const len = p.innerText.trim().length;
          let node = p.parentElement, weight = 1;
          for (let i = 0; node && i < 3; i++, node = node.parentElement, weight /= 2) {
            scores.set(node, (scores.get(node) || 0) + len * weight);
          }
        }
        let best = document.body, top = 0;
        for (const [node, score] of scores) {
          const hint = (node.className || '') + ' ' + (node.id || '');
          const s = SKIP.test(hint) ? score / 3 : score;
          if (s > top) { top = s; best = node; }
        }
        const allowed = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI', 'BLOCKQUOTE', 'PRE', 'CODE', 'IMG',
          'FIGURE', 'FIGCAPTION', 'A', 'EM', 'STRONG', 'B', 'I', 'BR', 'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH', 'HR', 'SUP', 'SUB', 'PICTURE']);
        const clean = (src) => {
          const out = [];
          for (const child of src.childNodes) {
            if (child.nodeType === Node.TEXT_NODE) { out.push(document.createTextNode(child.nodeValue)); continue; }
            if (child.nodeType !== Node.ELEMENT_NODE) continue;
            const hint = (child.className && child.className.baseVal === undefined ? child.className : '') + ' ' + (child.id || '');
            if (SKIP.test(hint) || ['SCRIPT', 'STYLE', 'NOSCRIPT', 'IFRAME', 'FORM', 'BUTTON', 'SVG', 'NAV', 'ASIDE', 'FOOTER', 'HEADER'].includes(child.tagName)) continue;
            if (child.tagName === 'PICTURE') { const img = child.querySelector('img'); if (img) out.push(...clean({ childNodes: [img] })); continue; }
            if (!allowed.has(child.tagName)) { out.push(...clean(child)); continue; }
            const el = document.createElement(child.tagName);
            if (child.tagName === 'A' && child.href) el.setAttribute('href', child.href);
            if (child.tagName === 'IMG') {
              const src = child.currentSrc || child.src || child.getAttribute('data-src');
              if (!src) continue;
              el.setAttribute('src', new URL(src, location.href).href);
              if (child.alt) el.setAttribute('alt', child.alt);
            }
            for (const n of clean(child)) el.appendChild(n);
            out.push(el);
          }
          return out;
        };
        const container = document.createElement('div');
        for (const n of clean(best)) container.appendChild(n);
        const meta = (name) => (document.querySelector(`meta[property="${name}"], meta[name="${name}"]`) || {}).content || '';
        const h1 = document.querySelector('h1');
        return {
          title: meta('og:title') || (h1 && h1.innerText.trim()) || document.title,
          byline: meta('author') || meta('article:author') || '',
          site: meta('og:site_name') || location.hostname.replace(/^www\./, ''),
          html: container.innerHTML,
          lang: document.documentElement.lang || '',
        };
      };

      // MARK: Translation
      let translatedNodes = null;
      window.__lbTextNodes = () => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: (n) => {
            const p = n.parentElement;
            if (!p || ['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'KBD', 'SAMP'].includes(p.tagName)) return NodeFilter.FILTER_REJECT;
            if (p.closest('[translate="no"], .notranslate, [contenteditable="true"]')) return NodeFilter.FILTER_REJECT;
            return /\p{L}{2}/u.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          },
        });
        const nodes = [];
        while (walker.nextNode() && nodes.length < 4000) nodes.push(walker.currentNode);
        translatedNodes = nodes.map((n) => ({ node: n, original: n.nodeValue }));
        return nodes.map((n) => n.nodeValue.trim());
      };
      window.__lbApplyTranslations = (texts) => {
        if (!translatedNodes) return 0;
        let n = 0;
        texts.forEach((t, i) => {
          const entry = translatedNodes[i];
          if (!entry || !t) return;
          const lead = entry.original.match(/^\s*/)[0], trail = entry.original.match(/\s*$/)[0];
          entry.node.nodeValue = lead + t + trail;
          n++;
        });
        return n;
      };
      window.__lbRestoreOriginal = () => {
        if (!translatedNodes) return;
        for (const e of translatedNodes) e.node.nodeValue = e.original;
        translatedNodes = null;
      };

      // MARK: Autofill
      // Hints are split into words first ("billingCity" → "billing city"), and every pattern is
      // word-bounded, so "sortOrder", "passport" or "landingPage" don't match city/country.
      const GUESS = [
        ['cc-number', /\b(card ?(number|no|num)|cc ?(number|num)|kartennummer)\b/],
        ['cc-name', /\b(name on card|card ?holder|cc ?name|karteninhaber)\b/],
        ['cc-exp-month', /\b(exp(iry|iration)? ?month|cc ?month|ablaufmonat)\b/],
        ['cc-exp-year', /\b(exp(iry|iration)? ?year|cc ?year|ablaufjahr)\b/],
        ['cc-exp', /\b(expiry|expiration|exp ?date|valid thru|ablaufdatum)\b/],
        ['email', /\b(e ?mail)\b/],
        ['tel', /\b(phone|telephone|tel|mobile|handy|telefon)\b/],
        ['given-name', /\b(first ?name|given ?name|vorname|fname)\b/],
        ['family-name', /\b(last ?name|family ?name|surname|nachname|lname)\b/],
        ['organization', /\b(company|organi[sz]ation|firma)\b/],
        ['address-line1', /\b(address ?(line)? ?1|street|strasse|straße|addr1|address)\b/],
        ['address-line2', /\b(address ?(line)? ?2|addr2|apartment|suite)\b/],
        ['postal-code', /\b(zip|zip ?code|postal ?code|postcode|plz)\b/],
        ['address-level2', /\b(city|town|ort|stadt|wohnort)\b/],
        ['address-level1', /\b(state|province|region|bundesland)\b/],
        ['country', /\b(country|land)\b/],
        ['name', /\b(full ?name|name|your ?name)\b/],
      ];
      const words = (s) => s.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
      const fieldKind = (el) => {
        const ac = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/).pop();
        if (ac && ac !== 'on' && ac !== 'off') return ac === 'street-address' ? 'address-line1' : ac;
        if (el.type === 'email') return 'email';
        if (el.type === 'tel') return 'tel';
        const hint = [el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
          el.labels && el.labels[0] && el.labels[0].innerText].filter(Boolean).join(' ');
        const text = words(hint);
        // Login, search and coupon boxes are never address or card fields.
        if (/\b(user ?name|login|search|captcha|coupon|promo|voucher|gutschein)\b/.test(text)) return null;
        const hit = GUESS.find(([, re]) => re.test(text));
        return hit ? hit[0] : null;
      };
      const fields = () => Array.from(document.querySelectorAll('input, select'))
        .filter((el) => !['hidden', 'submit', 'button', 'checkbox', 'radio', 'password', 'file'].includes(el.type) && el.offsetParent !== null);
      window.__lbFormKinds = () => {
        const kinds = fields().map(fieldKind).filter(Boolean);
        return { card: kinds.some((k) => k.startsWith('cc-')), address: kinds.some((k) => !k.startsWith('cc-')) };
      };
      window.__lbFillForm = (data, onlyCards) => {
        let filled = 0;
        for (const el of fields()) {
          let kind = fieldKind(el);
          if (!kind || (onlyCards && !kind.startsWith('cc-')) || (!onlyCards && kind.startsWith('cc-'))) continue;
          let value = data[kind];
          if (value === undefined && kind === 'name' && data['given-name']) value = (data['given-name'] + ' ' + (data['family-name'] || '')).trim();
          if (value === undefined && kind === 'street-address') value = data['address-line1'];
          if (value === undefined || value === '') continue;
          if (el.tagName === 'SELECT') {
            const v = String(value).toLowerCase();
            const opt = Array.from(el.options).find((o) => o.value.toLowerCase() === v || o.text.trim().toLowerCase() === v
              || (v.length <= 2 && Number(o.value) === Number(v))
              || (v.length === 4 && (o.value === v.slice(2) || o.text.trim() === v.slice(2))));
            if (!opt) continue;
            el.value = opt.value;
          } else {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
            setter.call(el, value);
          }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          filled++;
        }
        return filled;
      };
    })();
    """#
}
