import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            BookmarkSettings().tabItem { Label("Bookmarks", systemImage: "star") }
            WebsiteSettings().tabItem { Label("Websites", systemImage: "globe") }
            AutofillSettings().tabItem { Label("AutoFill", systemImage: "creditcard") }
            ProfileSettings().tabItem { Label("Profiles", systemImage: "person.2") }
            ExtensionSettings().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            SyncSettings().tabItem { Label("Sync", systemImage: "icloud") }
        }
        .frame(width: 560)
        .frame(minHeight: 420)
    }
}

/// The profile Settings pages act on: the front window's.
@MainActor
private var currentProfile: ProfileContext { WindowManager.shared.activeStore?.profile ?? .default }

private struct GeneralSettings: View {
    @AppStorage("searchEngine") private var engine = SearchEngine.duckduckgo.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("searchSuggestions") private var searchSuggestions = true
    @AppStorage("favoritesBarVisible") private var favoritesBar = true
    @AppStorage("askWhereToSave") private var askWhereToSave = false
    @State private var engineState = WebEngine.shared
    @State private var autofill = WebEngine.shared.isAutofillEnabled
    @State private var folder = DownloadSettings.folder

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Toggle("Show favorites bar", isOn: $favoritesBar)
            }
            Section("Search") {
                Picker("Search engine", selection: $engine) {
                    ForEach(SearchEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Show search suggestions while typing", isOn: $searchSuggestions)
                LabeledContent("History") {
                    Button("Clear History") { ProfileContext.all.forEach { $0.history.clear() } }
                }
            }
            Section("Downloads") {
                LabeledContent("Save files to") {
                    HStack {
                        Text(folder.lastPathComponent).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.directoryURL = folder
                            if panel.runModal() == .OK, let url = panel.url {
                                DownloadSettings.setFolder(url)
                                folder = DownloadSettings.folder
                            }
                        }
                    }
                }
                Toggle("Ask where to save each file", isOn: $askWhereToSave)
            }
            Section("Privacy & tools") {
                Toggle("Block ads & trackers", isOn: Binding(
                    get: { engineState.isAdBlockEnabled },
                    set: { on in WindowManager.shared.activeStore?.setAdBlock(on) ?? WebEngine.shared.setAdBlock(on) }))
                Toggle("Autofill & save passwords with Safespace", isOn: $autofill)
                    .onChange(of: autofill) { WebEngine.shared.setAutofill(autofill) }
                Toggle("Developer tools (Inspect Element)", isOn: Binding(
                    get: { engineState.developerToolsEnabled }, set: { WebEngine.shared.setDeveloperTools($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct BookmarkSettings: View {
    @State private var selection = Set<UUID>()

    var body: some View {
        let bookmarks = currentProfile.bookmarks
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu("Import") {
                    ForEach(BookmarkImporter.Source.allCases.filter(\.isInstalled)) { source in
                        Button("From \(source.label)") { BookmarkTools.importFrom(source, into: WindowManager.shared.activeStore) }
                    }
                    Divider()
                    Button("From HTML File…") { BookmarkTools.importHTML(into: WindowManager.shared.activeStore) }
                }
                .fixedSize()
                Button("Export…") { BookmarkTools.exportHTML(from: WindowManager.shared.activeStore) }
                Spacer()
                Button("Delete", role: .destructive) {
                    selection.forEach { bookmarks.remove($0) }
                    selection = []
                }
                .disabled(selection.isEmpty)
            }
            Table(bookmarks.items, selection: $selection) {
                TableColumn("Title") { b in Text(b.title).lineLimit(1) }
                TableColumn("Address") { b in Text(b.url.absoluteString).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn("Favorite") { b in
                    Toggle("", isOn: Binding(get: { b.isFavorite }, set: { v in bookmarks.update(b.id) { $0.isFavorite = v } }))
                        .labelsHidden()
                }
                .width(60)
                TableColumn("Folder") { b in Text(b.folder ?? "").foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(minHeight: 300)
            Text("Bookmarks of the \(currentProfile.profile.name) profile.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct WebsiteSettings: View {
    @State private var sites: [WebsiteData.Site] = []
    @State private var selection = Set<String>()
    @State private var loading = false

    private var permissions: SitePermissions { currentProfile.permissions }

    var body: some View {
        Form {
            Section("Permissions you've set (\(currentProfile.profile.name))") {
                if permissions.sites.isEmpty {
                    Text("Websites ask for camera and microphone access when they need it. Choices you save show up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(permissions.sites.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Text(permissions.sites[host, default: [:]].map { "\($0.key.label): \($0.value.label)" }.sorted().joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Button("Reset") { permissions.reset(host) }
                    }
                }
            }
            Section("Cookies and website data (\(currentProfile.profile.name))") {
                if loading { ProgressView().controlSize(.small) }
                List(sites, selection: $selection) { site in
                    HStack {
                        Text(site.name)
                        Spacer()
                        Text(site.summary).foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(site.name)
                }
                .frame(minHeight: 180)
                HStack {
                    Button("Remove") { remove(selection) }.disabled(selection.isEmpty)
                    Spacer()
                    Button("Remove All…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Remove all cookies and website data?"
                        alert.informativeText = "You'll be signed out of websites in the \(currentProfile.profile.name) profile."
                        alert.addButton(withTitle: "Remove All")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Task {
                            await WebsiteData.removeAll(from: currentProfile.dataStore)
                            await reload()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func remove(_ names: Set<String>) {
        Task {
            await WebsiteData.remove(names, from: currentProfile.dataStore)
            selection = []
            await reload()
        }
    }

    private func reload() async {
        loading = true
        sites = await WebsiteData.sites(in: currentProfile.dataStore)
        loading = false
    }
}

private struct AutofillSettings: View {
    @State private var autofill = AutofillStore.shared
    @State private var editingCard: AutofillStore.Card?

    var body: some View {
        @Bindable var autofill = autofill
        Form {
            Section("Your address") {
                HStack {
                    TextField("First name", text: $autofill.address.givenName)
                    TextField("Last name", text: $autofill.address.familyName)
                }
                TextField("Email", text: $autofill.address.email)
                TextField("Phone", text: $autofill.address.phone)
                TextField("Company", text: $autofill.address.organization)
                TextField("Street", text: $autofill.address.line1)
                TextField("Apartment, suite (optional)", text: $autofill.address.line2)
                HStack {
                    TextField("Postal code", text: $autofill.address.postalCode)
                    TextField("City", text: $autofill.address.city)
                }
                HStack {
                    TextField("State / region", text: $autofill.address.region)
                    TextField("Country", text: $autofill.address.country)
                }
            }
            Section {
                ForEach(autofill.cards) { card in
                    HStack {
                        Image(systemName: "creditcard")
                        Text(card.title)
                        Text(String(format: "%02d/%d", card.expMonth, card.expYear % 100)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") { editingCard = card }
                        Button("Delete", role: .destructive) { autofill.cards.removeAll { $0.id == card.id } }
                    }
                }
                Button("Add Card…") { editingCard = AutofillStore.Card() }
            } header: {
                Text("Payment cards")
            } footer: {
                Text("Stored in your Keychain on this Mac only. Filling a card asks for Touch ID or your password. Security codes are never saved. Press ⇧⌘A on a form to fill it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { autofill.saveNow() }
        .sheet(item: $editingCard) { card in
            CardEditor(card: card) { saved in
                if let saved {
                    if let i = autofill.cards.firstIndex(where: { $0.id == saved.id }) { autofill.cards[i] = saved } else { autofill.cards.append(saved) }
                }
                editingCard = nil
            }
        }
    }
}

private struct CardEditor: View {
    @State var card: AutofillStore.Card
    let done: (AutofillStore.Card?) -> Void

    var body: some View {
        Form {
            TextField("Nickname (optional)", text: $card.nickname)
            TextField("Name on card", text: $card.nameOnCard)
            TextField("Card number", text: $card.number)
            Picker("Expiry month", selection: $card.expMonth) { ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
            Picker("Expiry year", selection: $card.expYear) {
                let year = Calendar.current.component(.year, from: .now)
                ForEach(year...(year + 15), id: \.self) { Text(String($0)).tag($0) }
            }
            HStack {
                Button("Cancel") { done(nil) }
                Spacer()
                Button("Save") { done(card) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(card.digits.count < 12)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}

private struct ProfileSettings: View {
    @State private var manager = ProfileManager.shared
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                ForEach(manager.profiles) { profile in
                    HStack {
                        Menu {
                            ForEach(GroupColor.allCases) { c in Button(c.label) { manager.setColor(profile.id, c) } }
                        } label: {
                            Circle().fill(profile.color.accent).frame(width: 10, height: 10)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                        TextField("Name", text: Binding(get: { profile.name }, set: { manager.rename(profile.id, to: $0) }))
                            .textFieldStyle(.plain)
                        Spacer()
                        Button("New Window") { WindowManager.shared.newWindow(profileID: profile.id) }
                        if !profile.isDefault {
                            Button("Delete…", role: .destructive) { delete(profile) }
                        }
                    }
                }
            } header: {
                Text("Profiles")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Each profile has its own cookies and logins, history, bookmarks, website permissions, extensions and windows — e.g. Personal and Work.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let problem = manager.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
            Section {
                HStack {
                    TextField("New profile name", text: $newName)
                    Button("Add Profile") {
                        let p = manager.add(name: newName.isEmpty ? "Profile \(manager.profiles.count + 1)" : newName)
                        newName = ""
                        WindowManager.shared.newWindow(profileID: p.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func delete(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Delete the “\(profile.name)” profile?"
        alert.informativeText = "Its windows close, and its history, bookmarks, cookies and website data are deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await manager.delete(profile.id) }
    }
}

private struct ExtensionSettings: View {
    @State private var extensions = Extensions.shared

    var body: some View {
        let profile = currentProfile
        Form {
            if !Extensions.isSupported {
                Text("Extensions need macOS 15.4 or later.").foregroundStyle(.secondary)
            }
            Section {
                let records = extensions.records(for: profile.id)
                if records.isEmpty {
                    Text("No extensions in the \(profile.profile.name) profile yet.").foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    HStack {
                        Toggle(record.name, isOn: Binding(get: { record.enabled }, set: { extensions.setEnabled(record, $0) }))
                        Spacer()
                        Button("Options") { extensions.openOptions(record) }
                        Button("Remove", role: .destructive) { extensions.remove(record) }
                    }
                }
                Button("Add Extension…") { extensions.installInteractively(profileID: profile.id) }
                    .disabled(!Extensions.isSupported)
                if let error = extensions.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Extensions (\(profile.profile.name))")
            } footer: {
                Text("Add a WebExtension (the format Safari, Chrome and Firefox use) as an unpacked folder with a manifest.json or as a .zip — for example from the extension's GitHub releases. Stores like the Chrome Web Store can't install into LBrowser directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SyncSettings: View {
    @State private var sync = CloudSync.shared

    var body: some View {
        Form {
            Section {
                Toggle("Sync bookmarks and history with iCloud Drive", isOn: Binding(get: { sync.isEnabled }, set: { sync.setEnabled($0) }))
                    .disabled(!CloudSync.isAvailable && !sync.isEnabled)
                if let last = sync.lastSync {
                    LabeledContent("Last synced", value: last.formatted(date: .omitted, time: .shortened))
                }
                if let problem = sync.problem { Text(problem).foregroundStyle(.red).font(.caption) }
                Button("Sync Now") { sync.syncNow() }.disabled(!sync.isEnabled)
            } footer: {
                Text(CloudSync.isAvailable
                     ? "Turn this on on each Mac signed in to your Apple Account. LBrowser keeps its files in iCloud Drive › LBrowser; nothing goes to any other server."
                     : "iCloud Drive isn't turned on for this Mac (System Settings › Apple Account › iCloud).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
