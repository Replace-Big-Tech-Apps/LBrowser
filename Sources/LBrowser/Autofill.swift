import AppKit
import LocalAuthentication
import Observation
import Security

/// Saved address and payment cards for filling web forms, kept in the macOS Keychain.
/// Card numbers are only filled after Touch ID or the Mac password; security codes are never saved.
@Observable @MainActor
final class AutofillStore {
    /// Created on first use (Settings › AutoFill or ⇧⌘A), so LBrowser only reads the Keychain then.
    static var shared: AutofillStore {
        if let loaded { return loaded }
        let store = AutofillStore()
        loaded = store
        return store
    }
    private(set) static var loaded: AutofillStore?

    struct Address: Codable, Equatable {
        var givenName = ""
        var familyName = ""
        var organization = ""
        var email = ""
        var phone = ""
        var line1 = ""
        var line2 = ""
        var postalCode = ""
        var city = ""
        var region = ""
        var country = ""

        var isEmpty: Bool { self == Address() }

        var fields: [String: String] {
            [
                "given-name": givenName, "family-name": familyName,
                "name": "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces),
                "organization": organization, "email": email, "tel": phone,
                "address-line1": line1, "street-address": line1, "address-line2": line2,
                "postal-code": postalCode, "address-level2": city, "address-level1": region, "country": country,
                "country-name": country,
            ].filter { !$0.value.isEmpty }
        }
    }

    struct Card: Codable, Identifiable, Equatable {
        var id = UUID()
        var nickname = ""
        var nameOnCard = ""
        var number = ""
        var expMonth = 1
        var expYear = Calendar.current.component(.year, from: .now)

        var digits: String { number.filter(\.isNumber) }
        var masked: String { "•••• " + String(digits.suffix(4)) }
        var title: String { nickname.isEmpty ? masked : "\(nickname) \(masked)" }

        var fields: [String: String] {
            let mm = String(format: "%02d", expMonth)
            return [
                "cc-number": digits, "cc-name": nameOnCard, "cc-exp-month": mm,
                "cc-exp-year": String(expYear), "cc-exp": "\(mm)/\(String(expYear).suffix(2))",
            ].filter { !$0.value.isEmpty }
        }
    }

    // Settings edits these per keystroke, so Keychain writes are debounced.
    var address: Address { didSet { scheduleSave() } }
    var cards: [Card] { didSet { scheduleSave() } }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Writes pending changes now (Settings closing, app quitting). Untouched data isn't rewritten,
    /// which would make macOS ask for the Keychain password for nothing.
    func saveNow() {
        saveTask?.cancel()
        guard dirty else { return }
        dirty = false
        Keychain.save(address, account: "address")
        Keychain.save(cards, account: "cards")
    }

    private init() {
        address = Keychain.load(Address.self, account: "address") ?? Address()
        cards = Keychain.load([Card].self, account: "cards") ?? []
    }

    enum FillResult { case filled(Int), nothingToFill, noData, cancelled, needsPassword }

    /// Fills the address or card fields on the tab's page (⇧⌘A).
    func fill(_ tab: BrowserTab) async -> FillResult {
        guard let kinds = await PageScripts.call("return window.__lbFormKinds ? window.__lbFormKinds() : null", in: tab) as? [String: Bool]
        else { return .nothingToFill }
        var total = 0
        // Address first: a checkout page with card fields still gets the address when no card is saved.
        if kinds["address"] == true, !address.isEmpty {
            total += await fill(address.fields, cards: false, in: tab)
        }
        if kinds["card"] == true, !cards.isEmpty {
            guard let card = await chooseCard(window: tab.existingWebView?.window) else { return total > 0 ? .filled(total) : .cancelled }
            switch await authenticate() {
            case .ok: total += await fill(card.fields, cards: true, in: tab)
            case .unavailable: return total > 0 ? .filled(total) : .needsPassword
            case .failed: return total > 0 ? .filled(total) : .cancelled
            }
        }
        if total > 0 { return .filled(total) }
        return kinds.values.contains(true) ? .noData : .nothingToFill
    }

    private func fill(_ data: [String: String], cards: Bool, in tab: BrowserTab) async -> Int {
        (await PageScripts.call("return window.__lbFillForm(data, cards)", in: tab,
                                arguments: ["data": data, "cards": cards]) as? Int) ?? 0
    }

    private func chooseCard(window: NSWindow?) async -> Card? {
        if cards.count == 1 { return cards[0] }
        let alert = NSAlert()
        alert.messageText = "Which card?"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        popup.addItems(withTitles: cards.map(\.title))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        let response = if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        return response == .alertFirstButtonReturn ? cards[popup.indexOfSelectedItem] : nil
    }

    private enum AuthResult { case ok, failed, unavailable }

    /// Cards are only filled after Touch ID or the Mac password; without a way to check, they aren't filled.
    private func authenticate() async -> AuthResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "fill in your card details")) ?? false
        return ok ? .ok : .failed
    }
}

enum Keychain {
    private static let service = "dev.lbrowser.autofill"

    static func save<T: Encodable>(_ value: T, account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
    }

    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
