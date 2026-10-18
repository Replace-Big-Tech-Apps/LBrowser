import CoreLocation
import WebKit

/// Gives web pages `navigator.geolocation`. WebKit on the Mac has no location source of its own
/// (Safari supplies one), so a page-world script forwards requests here: LBrowser applies the
/// site's permission (asking if needed), then asks macOS's location service.
@MainActor
enum GeolocationBridge {
    static let handlerName = "lbGeo"
    static let handler = Handler()

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) async -> (Any?, String?) {
            let origin = message.frameInfo.securityOrigin
            // Like every browser, only secure pages (or this Mac) may ask for location.
            let local = ["localhost", "127.0.0.1", "::1"].contains(origin.host) || origin.host.hasSuffix(".localhost")
            guard origin.protocol == "https" || local, !origin.host.isEmpty,
                  let web = message.webView, let tab = BrowserTab.owner(of: web) else {
                return (Self.error(1, "Location isn't available on this page"), nil)
            }
            guard await tab.locationAllowed(for: origin.host, window: web.window) else {
                return (Self.error(1, "User denied Geolocation"), nil)
            }
            do {
                let location = try await LocationService.shared.current()
                return ([
                    "lat": location.coordinate.latitude, "lon": location.coordinate.longitude,
                    "acc": location.horizontalAccuracy,
                    "alt": location.verticalAccuracy >= 0 ? location.altitude as Any : NSNull(),
                    "altAcc": location.verticalAccuracy >= 0 ? location.verticalAccuracy as Any : NSNull(),
                    "heading": location.course >= 0 ? location.course as Any : NSNull(),
                    "speed": location.speed >= 0 ? location.speed as Any : NSNull(),
                    "ts": location.timestamp.timeIntervalSince1970 * 1000,
                ], nil)
            } catch LocationService.Failure.denied {
                return (Self.error(1, "LBrowser isn't allowed to use your location (System Settings › Privacy & Security › Location Services)"), nil)
            } catch {
                return (Self.error(2, "Position unavailable"), nil)
            }
        }

        private static func error(_ code: Int, _ message: String) -> [String: Any] { ["code": code, "error": message] }
    }

    static let source = #"""
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lbGeo;
      if (!handler || !('geolocation' in navigator)) return;
      const nil = (v) => (v === undefined ? null : v);
      const position = (r) => {
        const coords = { latitude: r.lat, longitude: r.lon, accuracy: r.acc, altitude: nil(r.alt),
          altitudeAccuracy: nil(r.altAcc), heading: nil(r.heading), speed: nil(r.speed) };
        coords.toJSON = () => ({ ...coords, toJSON: undefined });
        const pos = { coords, timestamp: r.ts };
        pos.toJSON = () => ({ coords: coords.toJSON(), timestamp: r.ts });
        return pos;
      };
      const failure = (code, message) => ({ code, message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
      const request = (ok, fail) => handler.postMessage({ op: 'get' }).then(
        (r) => (r && r.error ? fail && fail(failure(r.code, r.error)) : ok(position(r))),
        () => fail && fail(failure(2, 'Position unavailable')));
      const watches = new Map();
      let nextID = 1;
      const geolocation = {
        getCurrentPosition(ok, fail) { request(ok, fail); },
        watchPosition(ok, fail) {
          const id = nextID++;
          const tick = () => request(ok, fail);
          tick();
          watches.set(id, setInterval(tick, 15000));
          return id;
        },
        clearWatch(id) { clearInterval(watches.get(id)); watches.delete(id); },
      };
      try { Object.defineProperty(Navigator.prototype, 'geolocation', { get: () => geolocation, configurable: true }); } catch (e) {}
    })();
    """#
}

/// One-shot location fixes from Core Location, asking macOS for permission the first time.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    enum Failure: Error { case denied, unavailable }

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, Error>] = []
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            // macOS shows "LBrowser would like to use your current location" now.
            await withCheckedContinuation { done in
                authorizationWaiters.append(done)
                if authorizationWaiters.count == 1 { manager.requestWhenInUseAuthorization() }
            }
        }
        switch manager.authorizationStatus {
        case .denied, .restricted, .notDetermined: throw Failure.denied
        default: break
        }
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -60 { return recent }
        return try await withCheckedThrowingContinuation { done in
            waiting.append(done)
            if waiting.count == 1 { manager.requestLocation() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authorizationWaiters
            authorizationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last else { return }
            let waiters = waiting
            waiting = []
            waiters.forEach { $0.resume(returning: location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let denied = (error as? CLError)?.code == .denied
            let waiters = waiting
            waiting = []
            waiters.forEach { $0.resume(throwing: denied ? Failure.denied : Failure.unavailable) }
        }
    }
}
