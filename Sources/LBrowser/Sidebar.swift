import SwiftUI

struct Sidebar: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.groups.enumerated()), id: \.element.id) { i, group in
                        GroupSection(group: group, index: i + 1)
                    }

                    SectionHeader(title: store.isPrivate ? "Private tabs" : "Tabs", count: store.looseTabs.count)
                        .padding(.top, store.groups.isEmpty ? 16 : 20)
                        .dropDestination(for: String.self) { items, _ in
                            store.handleDrop(items, group: nil, before: store.looseTabs.first)
                        }
                    ForEach(store.looseTabs) { TabRow(tab: $0, group: nil) }

                    // Drop here to ungroup.
                    Color.clear
                        .frame(height: 80)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            store.handleDrop(items, group: nil, before: nil)
                        }
                }
            }
            .scrollIndicators(.never)

            HStack(spacing: 0) {
                Segment(index: 1, title: "New tab") { store.newTab() }
                Orbis.line.frame(width: 1)
                Segment(index: 2, title: "New group") { store.newGroup() }
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: Orbis.radiusXS))
            .overlay(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(Orbis.lineStrong))
            .padding(16)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).eyebrow()
            Spacer()
            Text(String(format: "%02d", count)).eyebrow()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct GroupSection: View {
    @Environment(BrowserStore.self) private var store
    @Bindable var group: TabGroup
    let index: Int
    @State private var renaming = false
    @State private var draft = ""
    @State private var hover = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if group.collapsed {
                collapsedStrip
            } else {
                ForEach(group.tabs) { TabRow(tab: $0, group: group) }
                if group.tabs.isEmpty {
                    Text("Drop tabs here").eyebrow(size: 8)
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
            }
        }
        .padding(.bottom, 6)
        .hairline(.bottom)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, group: group, before: nil)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", index)).eyebrow(size: 8)
            RoundedRectangle(cornerRadius: 1).fill(group.color.accent).frame(width: 6, height: 6)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(OrbisFont.display(9))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: nameFocused) { if !nameFocused { commitRename() } }
            } else {
                Text(group.name).eyebrow(Orbis.ink).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(String(format: "%02d", group.tabs.count)).eyebrow(size: 8)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 18, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hover ? 1 : 0.35)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Orbis.inkMute)
                .rotationEffect(.degrees(group.collapsed ? -90 : 0))
        }
        .padding(.horizontal, 20)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.23)) { group.collapsed.toggle() } }
        .contextMenu { menuItems }
    }

    private var collapsedStrip: some View {
        HStack(spacing: 4) {
            ForEach(group.tabs.prefix(10)) { tab in
                Favicon(tab: tab)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: Orbis.radiusXS)
                        .strokeBorder(store.selectedID == tab.id ? Orbis.ink : Orbis.line))
                    .contentShape(Rectangle())
                    .onTapGesture { store.select(tab) }
                    .help(tab.title)
            }
            if group.tabs.count > 10 {
                Text("+\(group.tabs.count - 10)").eyebrow(size: 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var menuItems: some View {
        Button("New Tab in Group") { store.newTab(in: group) }
        Button("Rename…") {
            draft = group.name
            renaming = true
            DispatchQueue.main.async { nameFocused = true }
        }
        Menu("Color") {
            ForEach(GroupColor.allCases) { color in
                Button {
                    group.color = color
                    store.scheduleSave()
                } label: {
                    if color == group.color { Label(color.label, systemImage: "checkmark") } else { Text(color.label) }
                }
            }
        }
        Divider()
        Button("Ungroup") { store.ungroup(group) }
        Button("Close Group", role: .destructive) { store.closeGroup(group) }
    }

    private func commitRename() {
        guard renaming else { return }
        let name = draft.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { group.name = name }
        renaming = false
        store.scheduleSave()
    }
}

struct TabRow: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    let group: TabGroup?
    @State private var hover = false
    @State private var closeHover = false

    private var isSelected: Bool { store.selectedID == tab.id }

    var body: some View {
        HStack(spacing: 10) {
            Favicon(tab: tab)
            Text(tab.title)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Orbis.ink : Orbis.inkMute)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hover {
                Button { store.close(tab) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: Orbis.radiusXS).strokeBorder(closeHover ? Orbis.lineStrong : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Orbis.inkMute)
                .onHover { closeHover = $0 }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 32)
        .background(isSelected ? Orbis.surface : (hover ? Orbis.surface.opacity(0.6) : .clear))
        .overlay(alignment: .leading) {
            if isSelected { (group?.color.accent ?? Orbis.ink).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .onHover { hover = $0 }
        .draggable(tab.id.uuidString) {
            HStack { Favicon(tab: tab); Text(tab.title).font(.system(size: 12)).lineLimit(1) }
                .padding(8)
                .background(Orbis.canvas)
                .overlay(Rectangle().strokeBorder(Orbis.lineStrong))
        }
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, group: group, before: tab)
        }
        .contextMenu {
            Menu("Move to Group") {
                ForEach(store.groups) { g in
                    Button(g.name) { store.move(tab, to: g, before: nil) }.disabled(g === group)
                }
                if !store.groups.isEmpty { Divider() }
                Button("New Group") { store.newGroup(with: tab) }
            }
            if group != nil {
                Button("Remove from Group") { store.move(tab, to: nil, before: nil) }
            }
            Divider()
            Button("Duplicate Tab") { store.duplicate(tab) }
            Button("Close Tab") { store.close(tab) }
        }
    }
}

struct Favicon: View {
    let tab: BrowserTab

    var body: some View {
        Group {
            if tab.isLoading {
                PulseDot()
            } else if !tab.isPrivate, let url = tab.faviconURL {
                AsyncImage(url: url) { image in
                    image.resizable().interpolation(.high).scaledToFit()
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: 14, height: 14)
    }

    private var placeholder: some View {
        Image(systemName: tab.url == nil ? "circle.dotted" : "globe")
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(Orbis.inkMute)
    }
}

/// ORBIS's pulsing live dot.
struct PulseDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Orbis.alert)
            .frame(width: 5, height: 5)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
