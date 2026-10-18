import SwiftUI

/// Safari-style sidebar: a list of tab groups on top, and below it only the selected group's tabs.
struct Sidebar: View {
    @Environment(BrowserStore.self) private var store
    @AppStorage("groupListExpanded") private var groupsExpanded = true

    var body: some View {
        let active = store.activeGroup
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.pinnedTabs.isEmpty { PinnedTabsGrid().padding(.top, 14) }

                    Button { withAnimation(.easeOut(duration: 0.2)) { groupsExpanded.toggle() } } label: {
                        HStack(spacing: 8) {
                            Text("Tab groups").eyebrow()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Orbis.inkWhisper)
                                .rotationEffect(.degrees(groupsExpanded ? 0 : -90))
                            Spacer()
                            Text(String(format: "%02d", store.groups.count)).eyebrow()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if groupsExpanded {
                        GroupRow(group: nil)
                        ForEach(store.groups) { GroupRow(group: $0) }
                        NewGroupRow()
                    } else if let active {
                        GroupRow(group: active)
                    }

                    Orbis.line.frame(height: 1).padding(.top, 10)

                    SectionHeader(title: active?.name ?? (store.isPrivate ? "Private tabs" : "Tabs"),
                                  count: store.visibleTabs.count)
                        .padding(.top, 16)
                        .dropDestination(for: String.self) { items, _ in
                            store.handleDrop(items, group: active, before: store.visibleTabs.first)
                        }
                    ForEach(store.visibleTabs) { TabRow(tab: $0, group: active) }

                    // Drop below the list to move a tab to the end.
                    Color.clear
                        .frame(height: 80)
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            store.handleDrop(items, group: active, before: nil)
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
            Text(title).eyebrow().lineLimit(1)
            Spacer()
            Text(String(format: "%02d", count)).eyebrow()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// One entry in the group list; `nil` is the default, ungrouped tabs ("12 Tabs" in Safari).
struct GroupRow: View {
    @Environment(BrowserStore.self) private var store
    let group: TabGroup?
    @State private var hover = false
    @State private var dropTarget = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var isActive: Bool { store.activeGroup === group }
    private var count: Int { store.tabs(in: group).count }
    private var renaming: Bool { group != nil && store.renamingGroupID == group?.id }

    private var title: String {
        if let group { return group.name }
        if store.isPrivate { return "Private" }
        return count == 1 ? "1 Tab" : "\(count) Tabs"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group == nil ? "square.on.square" : "square.stack")
                .font(.system(size: 12))
                .foregroundStyle(group?.color.accent ?? Orbis.inkMute)
                .frame(width: 16)
            if renaming, let group {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit { store.rename(group, to: draft) }
                    .onExitCommand { store.rename(group, to: group.name) }
                    .onChange(of: nameFocused) { if !nameFocused, renaming { store.rename(group, to: draft) } }
                    .onAppear {
                        draft = group.name
                        DispatchQueue.main.async { nameFocused = true }
                    }
            } else {
                Text(title)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Orbis.ink : Orbis.inkMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if group != nil {
                Text(String(format: "%02d", count)).eyebrow(size: 8)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: 32)
        .background(isActive ? Orbis.surface : (hover ? Orbis.surface.opacity(0.6) : .clear))
        .overlay {
            if dropTarget { Rectangle().strokeBorder(Orbis.ink, lineWidth: 1).padding(.horizontal, 8) }
        }
        .overlay(alignment: .leading) {
            if isActive { (group?.color.accent ?? Orbis.ink).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { store.switchTo(group) } }
        .onHover { hover = $0 }
        .dropDestination(for: String.self) { items, _ in
            store.handleDrop(items, group: group, before: nil)
        } isTargeted: { dropTarget = $0 }
        .contextMenu {
            Button("New Tab") { store.newTab(in: group) }
            if let group {
                Button("Rename…") { store.renamingGroupID = group.id }
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
                Button("Copy Links") { copyLinks() }
                Divider()
                Button("Delete Group", role: .destructive) { store.closeGroup(group) }
            } else {
                Button("Copy Links") { copyLinks() }
            }
        }
    }

    private func copyLinks() {
        let links = store.tabs(in: group).compactMap { $0.url?.absoluteString }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links, forType: .string)
    }
}

private struct NewGroupRow: View {
    @Environment(BrowserStore.self) private var store
    @State private var hover = false

    var body: some View {
        Button { store.newGroup() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 11)).frame(width: 16)
                Text("New Tab Group").font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover ? Orbis.ink : Orbis.inkWhisper)
            .padding(.leading, 20)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("New Tab Group (⌃⌘N)")
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
            if tab.isPlayingAudio || tab.isMuted {
                AudioButton(tab: tab)
            }
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
            Button("Pin Tab") { store.pin(tab) }
            if tab.isPlayingAudio || tab.isMuted {
                Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) }
            }
            Menu("Move to Tab Group") {
                if group != nil {
                    Button(store.isPrivate ? "Private" : "Tabs") { store.move(tab, to: nil, before: nil) }
                }
                ForEach(store.groups) { g in
                    Button(g.name) { store.move(tab, to: g, before: nil) }.disabled(g === group)
                }
                Divider()
                Button("New Tab Group") { store.newGroup(with: tab) }
            }
            if WindowManager.shared.canMoveToNewWindow(tab) {
                Button("Move to New Window") { WindowManager.shared.moveToNewWindow(tab) }
            }
            Divider()
            Button("Duplicate Tab") { store.duplicate(tab) }
            Button("Close Tab") { store.close(tab) }
        }
    }
}

/// Speaker in a tab row: shows the tab plays sound; click to mute or unmute.
struct AudioButton: View {
    let tab: BrowserTab

    var body: some View {
        Button { tab.setMuted(!tab.isMuted) } label: {
            Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9))
                .foregroundStyle(tab.isMuted ? Orbis.inkWhisper : Orbis.alert)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.isMuted ? "Unmute Tab" : "Mute Tab")
    }
}

/// Pinned tabs as a grid of favicons above the group list; shared by every tab group.
struct PinnedTabsGrid: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 60), spacing: 6)], spacing: 6) {
            ForEach(store.pinnedTabs) { PinnedTile(tab: $0) }
        }
        .padding(.horizontal, 16)
        .dropDestination(for: String.self) { items, _ in store.handlePinnedDrop(items, before: nil) }
    }
}

private struct PinnedTile: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    @State private var hover = false

    var body: some View {
        let selected = store.selectedID == tab.id
        ZStack(alignment: .topTrailing) {
            Favicon(tab: tab)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: Orbis.radiusSM).fill(selected ? Orbis.surfaceHover : (hover ? Orbis.surface : .clear)))
                .overlay(RoundedRectangle(cornerRadius: Orbis.radiusSM).strokeBorder(selected ? Orbis.ink : Orbis.line))
            if tab.isPlayingAudio || tab.isMuted {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(tab.isMuted ? Orbis.inkWhisper : Orbis.alert)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .onHover { hover = $0 }
        .help(tab.title)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in store.handlePinnedDrop(items, before: tab) }
        .contextMenu {
            Button("Unpin Tab") { store.unpin(tab) }
            if tab.isPlayingAudio || tab.isMuted {
                Button(tab.isMuted ? "Unmute Tab" : "Mute Tab") { tab.setMuted(!tab.isMuted) }
            }
            if WindowManager.shared.canMoveToNewWindow(tab) {
                Button("Move to New Window") { WindowManager.shared.moveToNewWindow(tab) }
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
