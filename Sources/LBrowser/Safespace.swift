import AppKit
import Observation
import WebKit

/// Talks to the Safespace password manager over its local socket
/// (`~/Library/Application Support/Safespace/browser.sock`). Safespace only answers while its vault
/// is unlocked, and only to a signed LBrowser.app.
enum SafespaceClient {
    static let bundleID = "app.safespace.mac"
    static let stateChanged = Notification.Name("app.safespace.mac.bridge.stateChanged")

    struct Login: Codable, Sendable {
        var id: UUID
        var title: String
        var username: String
    }

    struct Response: Decodable, Sendable {
        var ok: Bool
        var error: String?
        var state: String?
        var logins: [Login]?
        var password: String?
        var result: String?
    }

    private struct Request: Encodable {
        var op: String
        var url: String?
        var id: UUID?
        var username: String?
        var password: String?
    }

    static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Safespace/browser.sock").path
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func find(origin: URL) async -> Response? {
        await send(Request(op: "find", url: origin.absoluteString))
    }

    static func fill(origin: URL, id: UUID) async -> Response? {
        await send(Request(op: "fill", url: origin.absoluteString, id: id))
    }

    static func save(origin: URL, username: String, password: String) async -> Response? {
        await send(Request(op: "save", url: origin.absoluteString, username: username, password: password))
    }

    /// Launches or brings Safespace to the front so the vault can be unlocked (Touch ID prompts there).
    @MainActor
    static func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// `nil` means Safespace isn't running (or the socket couldn't be reached).
    private static func send(_ request: Request) async -> Response? {
        guard let body = try? JSONEncoder().encode(request) else { return nil }
        let path = socketPath
        return await Task.detached(priority: .userInitiated) {
            exchange(body, path: path).flatMap { try? JSONDecoder().decode(Response.self, from: $0) }
        }.value
    }

    private static func exchange(_ body: Data, path: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var payload = body
        payload.append(UInt8(ascii: "\n"))
        let sent = payload.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard sent else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while response.count < 1 << 20 {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        return response.isEmpty ? nil : response
    }
}

/// Autofill + automatic saving for login forms, backed by Safespace.
///
/// The form script runs in its own content world, so page scripts can't see the saved usernames it
/// shows or call into Safespace. A password is only fetched when the user clicks a login in the
/// dropdown, and only for the origin of the frame that asked.
@Observable @MainActor
final class SafespaceAutofill: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = SafespaceAutofill()
    static let world = WKContentWorld.world(name: "LBrowserSafespace")
    static let handlerName = "safespace"

    struct Notice: Equatable {
        var message: String
        /// Shown with "Unlock" / "Not now" buttons while a login waits for the vault.
        var awaitsUnlock = false
    }

    private struct PendingSave {
        var origin: URL
        var username: String
        var password: String
    }

    private(set) var notice: Notice?

    @ObservationIgnored private var pending: [PendingSave] = []
    /// Usernames from multi-step sign-ins ("enter email" → next page "enter password"), per host.
    @ObservationIgnored private var identifiers: [String: (username: String, at: Date)] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    override init() {
        super.init()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: SafespaceClient.stateChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SafespaceAutofill.shared.safespaceStateChanged() }
        }
    }

    var userScript: WKUserScript {
        WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.world)
    }

    // MARK: Messages from the page script

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let origin = Self.fillableOrigin(of: message.frameInfo) else { return (nil, nil) }

        switch type {
        case "find":
            guard let response = await SafespaceClient.find(origin: origin) else {
                return (["state": SafespaceClient.isInstalled ? "closed" : "missing"], nil)
            }
            let logins = (response.logins ?? []).map {
                ["id": $0.id.uuidString, "title": $0.title, "username": $0.username]
            }
            return (["state": response.state ?? "locked", "logins": logins], nil)

        case "fill":
            guard let id = (body["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let password = await SafespaceClient.fill(origin: origin, id: id)?.password else { return (nil, nil) }
            return (["password": password], nil)

        case "identifier":
            if let username = body["username"] as? String, !username.isEmpty, let host = origin.host() {
                identifiers[host] = (username, Date())
            }
            return (nil, nil)

        case "save":
            guard let password = body["password"] as? String, !password.isEmpty else { return (nil, nil) }
            var username = (body["username"] as? String) ?? ""
            if username.isEmpty, let host = origin.host(), let recent = identifiers[host],
               Date().timeIntervalSince(recent.at) < 600 {
                username = recent.username
            }
            await save(PendingSave(origin: origin, username: username, password: password))
            return (nil, nil)

        case "unlock":
            SafespaceClient.openApp()
            return (nil, nil)

        default:
            return (nil, nil)
        }
    }

    /// `scheme://host[:port]` of the frame, only for HTTPS (or plain HTTP on this machine).
    private static func fillableOrigin(of frame: WKFrameInfo) -> URL? {
        let origin = frame.securityOrigin
        guard !origin.host.isEmpty else { return nil }
        let local = ["localhost", "127.0.0.1", "::1"].contains(origin.host) || origin.host.hasSuffix(".localhost")
        guard origin.protocol == "https" || (origin.protocol == "http" && local) else { return nil }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = origin.port }
        return components.url
    }

    // MARK: Saving

    private func save(_ login: PendingSave) async {
        guard let response = await SafespaceClient.save(
            origin: login.origin, username: login.username, password: login.password)
        else {
            guard SafespaceClient.isInstalled else { return }
            queue(login)
            return
        }
        if response.ok {
            switch response.result {
            case "created": show(Notice(message: "Login saved to Safespace"))
            case "updated": show(Notice(message: "Password updated in Safespace"))
            default: break
            }
        } else if response.error == "locked" {
            queue(login)
        }
        // "disabled" / "setup": the user hasn't opted in, so drop it quietly.
    }

    private func queue(_ login: PendingSave) {
        pending.removeAll { $0.origin == login.origin && $0.username == login.username }
        pending.append(login)
        let host = login.origin.host() ?? "this site"
        show(Notice(message: "Unlock Safespace to save your login for \(host)", awaitsUnlock: true), autoHide: false)
    }

    func unlockTapped() {
        SafespaceClient.openApp()
    }

    func dismissNotice() {
        if notice?.awaitsUnlock == true { pending.removeAll() }
        notice = nil
    }

    private func safespaceStateChanged() {
        Task {
            let waiting = pending
            pending.removeAll()
            if waiting.isEmpty, notice?.awaitsUnlock == true { notice = nil }
            for login in waiting { await save(login) }
            // Let an open login dropdown pick up the newly unlocked vault.
            _ = try? await BrowserStore.shared.selected?.existingWebView?
                .evaluateJavaScript("window.__safespaceRefresh && window.__safespaceRefresh()", in: nil, contentWorld: Self.world)
        }
    }

    private func show(_ notice: Notice, autoHide: Bool = true) {
        self.notice = notice
        noticeTask?.cancel()
        guard autoHide else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.notice == notice else { return }
            self?.notice = nil
        }
    }
}

extension SafespaceAutofill {
    /// Finds login forms, shows the saved-login dropdown and reports submitted credentials.
    static let script = #"""
    (() => {
      if (window.__safespaceInstalled) return;
      window.__safespaceInstalled = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.safespace;
      if (!handler) return;
      const post = (msg) => handler.postMessage(msg).catch(() => null);

      const TEXT_TYPES = new Set(['text', 'email', 'tel']);
      const USERISH = /user|mail|login|account|ident|member|phone/i;
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
      };
      const isPassword = (el) => el instanceof HTMLInputElement && el.type === 'password'
        && el.autocomplete !== 'one-time-code';
      const isText = (el) => el instanceof HTMLInputElement && TEXT_TYPES.has(el.type);
      const looksLikeUser = (el) => isText(el) && (el.type === 'email' || /username|email/.test(el.autocomplete)
        || USERISH.test(`${el.name} ${el.id} ${el.placeholder} ${el.getAttribute('aria-label') || ''}`));
      const scopeOf = (el) => el.form || el.closest('form') || document;
      const passwords = (root) => [...root.querySelectorAll('input[type=password]')].filter((p) => isPassword(p) && visible(p));

      function usernameField(root, before) {
        const inputs = [...root.querySelectorAll('input')].filter((i) => isText(i) && visible(i));
        const explicit = inputs.find((i) => /username|email/.test(i.autocomplete));
        if (explicit) return explicit;
        let nearest = null;
        if (before) for (const i of inputs) if (i.compareDocumentPosition(before) & Node.DOCUMENT_POSITION_FOLLOWING) nearest = i;
        return nearest || inputs.find(looksLikeUser) || null;
      }

      function isLoginField(el) {
        if (isPassword(el)) return el.autocomplete !== 'new-password';
        if (!isText(el)) return false;
        const pws = passwords(scopeOf(el));
        if (pws.length) return usernameField(scopeOf(el), pws[0]) === el;
        return looksLikeUser(el) && !!el.closest('form');
      }

      function setValue(el, value) {
        if (!el) return;
        el.focus();
        el.value = value;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      // ---- Dropdown ---------------------------------------------------------
      const host = document.createElement('lbrowser-safespace');
      host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;display:none;';
      const shadow = host.attachShadow({ mode: 'closed' });
      shadow.innerHTML = `<style>
        :host { all: initial; }
        .box { font: 12px -apple-system, BlinkMacSystemFont, sans-serif; background: #fefefe; color: #0a0a0b;
          border: 1px solid rgba(0,0,0,.14); border-radius: 8px; box-shadow: 0 10px 30px rgba(0,0,0,.12);
          overflow: hidden; min-width: 240px; max-width: 360px; }
        .head { display: flex; align-items: center; gap: 6px; padding: 7px 10px 6px; font-size: 9px;
          letter-spacing: .14em; text-transform: uppercase; color: rgba(10,10,11,.45);
          border-bottom: 1px solid rgba(0,0,0,.08); }
        .dot { width: 5px; height: 5px; border-radius: 50%; background: #d4860a; }
        button { all: unset; box-sizing: border-box; display: flex; flex-direction: column; gap: 1px; width: 100%;
          padding: 7px 10px; cursor: default; }
        button:hover, button.sel { background: rgba(0,0,0,.05); }
        .u { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .t { font-size: 11px; color: rgba(10,10,11,.52); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        @media (prefers-color-scheme: dark) {
          .box { background: #141416; color: #f5f5f5; border-color: rgba(255,255,255,.14); }
          .head { color: rgba(245,245,245,.5); border-color: rgba(255,255,255,.1); }
          .dot { background: #f0a22a; }
          button:hover, button.sel { background: rgba(255,255,255,.07); }
          .t { color: rgba(245,245,245,.56); }
        }
      </style><div class="box"><div class="head"><span class="dot"></span>Safespace</div><div class="list"></div></div>`;
      const list = shadow.querySelector('.list');
      let field = null;
      let items = [];
      let selected = -1;
      let filling = false;

      function hide() { host.style.display = 'none'; field = null; items = []; selected = -1; }

      function place() {
        if (!field || !field.isConnected) return hide();
        const r = field.getBoundingClientRect();
        host.style.left = `${Math.max(4, r.left)}px`;
        host.style.top = `${r.bottom + 4}px`;
        host.style.minWidth = `${r.width}px`;
      }

      function render(entries) {
        list.textContent = '';
        items = entries;
        entries.forEach((entry, index) => {
          const b = document.createElement('button');
          const u = document.createElement('span'); u.className = 'u'; u.textContent = entry.primary;
          const t = document.createElement('span'); t.className = 't'; t.textContent = entry.secondary;
          b.append(u, t);
          b.addEventListener('mousedown', (e) => e.preventDefault());
          b.addEventListener('click', (e) => { if (e.isTrusted) choose(index); });
          list.append(b);
        });
        if (!entries.length) return hide();
        if (!host.isConnected) document.documentElement.append(host);
        host.style.display = 'block';
        place();
      }

      function highlight(index) {
        selected = index;
        [...list.children].forEach((b, i) => b.classList.toggle('sel', i === index));
      }

      async function choose(index) {
        const entry = items[index];
        const target = field;
        hide();
        if (!entry || !target) return;
        if (entry.action) return entry.action();
        const reply = await post({ type: 'fill', id: entry.id });
        if (!reply || !reply.password) return;
        const root = scopeOf(target);
        const pw = isPassword(target) ? target : passwords(root)[0];
        const user = isPassword(target) ? usernameField(root, target) : target;
        filling = true;
        if (user && entry.username) setValue(user, entry.username);
        if (pw) setValue(pw, reply.password);
        filling = false;
      }

      let queryToken = 0;
      async function show(el) {
        const token = ++queryToken;
        const reply = await post({ type: 'find' });
        if (token !== queryToken || document.activeElement !== el || !reply) return;
        field = el;
        if (reply.state === 'unlocked') {
          render((reply.logins || []).map((l) => ({ id: l.id, username: l.username,
            primary: l.username || '(no username)', secondary: l.title })));
        } else if (reply.state === 'locked' || reply.state === 'closed') {
          render([{ primary: reply.state === 'locked' ? 'Unlock Safespace' : 'Open Safespace',
            secondary: 'to fill your saved login', action: () => post({ type: 'unlock' }) }]);
        } else {
          hide();
        }
      }

      window.__safespaceRefresh = () => {
        const el = document.activeElement;
        if (el && isLoginField(el)) show(el);
      };

      document.addEventListener('focusin', (e) => {
        if (filling) return;
        const el = e.composedPath()[0];
        if (el instanceof HTMLInputElement && isLoginField(el)) show(el); else hide();
      }, true);
      document.addEventListener('focusout', () => setTimeout(() => {
        if (field && document.activeElement !== field) hide();
      }, 0), true);
      document.addEventListener('keydown', (e) => {
        if (!field || host.style.display === 'none' || !e.isTrusted) return;
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          const n = items.length;
          highlight(((selected + (e.key === 'ArrowDown' ? 1 : -1)) % n + n) % n);
        } else if (e.key === 'Enter' && selected >= 0) {
          e.preventDefault(); e.stopImmediatePropagation(); choose(selected);
        } else if (e.key === 'Escape') {
          hide();
        }
      }, true);
      document.addEventListener('mousedown', (e) => { if (!e.composedPath().includes(host)) hide(); }, true);
      window.addEventListener('scroll', place, true);
      window.addEventListener('resize', place);

      // ---- Capturing submitted logins ---------------------------------------
      let last = '';
      let lastAt = 0;
      function capture(root) {
        const filled = passwords(root).filter((p) => p.value);
        if (!filled.length) {
          const user = usernameField(root, null);
          if (user && user.value && looksLikeUser(user)) post({ type: 'identifier', username: user.value.trim() });
          return;
        }
        // Sign-up (new + confirm) and change-password (current + new [+ confirm]) forms: take the new one.
        let password = filled[0].value;
        if (filled.length >= 2) {
          const [a, b] = filled.slice(-2);
          password = a.value === b.value ? b.value : filled[1].value;
        }
        const user = usernameField(root, filled[0]);
        const username = user && user.value ? user.value.trim() : '';
        const key = `${username}\u0000${password}`;
        if (key === last && Date.now() - lastAt < 3000) return;
        last = key; lastAt = Date.now();
        post({ type: 'save', username, password });
      }

      document.addEventListener('submit', (e) => { if (e.target instanceof HTMLFormElement) capture(e.target); }, true);
      document.addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const button = e.target instanceof Element && e.target.closest('button, input[type=submit], input[type=image], [role=button]');
        if (button) capture(scopeOf(button));
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.key !== 'Enter' || !e.isTrusted || !(e.target instanceof HTMLInputElement)) return;
        if (field && host.style.display !== 'none' && selected >= 0) return;
        capture(scopeOf(e.target));
      }, true);
    })();
    """#
}
