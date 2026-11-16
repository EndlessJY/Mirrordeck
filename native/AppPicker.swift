import SwiftUI

/// Picks an app of the device to open in its own Mac window.
struct AppPickerView: View {
    let device: ADBDevice
    let options: MirrorOptions
    @ObservedObject private var store = AppWindowStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?

    private var apps: [DeviceApp] { store.apps[device.id] ?? [] }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Matches by name, package, pinyin or initials; the best matches first.
    private var filtered: [DeviceApp] {
        guard searching else { return apps }
        return apps.enumerated()
            .compactMap { index, app in app.rank(for: query).map { (app, $0, index) } }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }

    /// Recently opened apps that are still installed, newest first.
    private var recentApps: [DeviceApp] {
        let byPackage = Dictionary(apps.map { ($0.package, $0) }, uniquingKeysWith: { a, _ in a })
        return store.recentPackages(for: device).compactMap { byPackage[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .tint(Theme.accent)
        .secondaryPanelSize(width: 480, height: 560)
        .onAppear { store.load(device) }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "macwindow.on.rectangle", size: 30, style: .tinted(Theme.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text("在独立窗口中打开应用").font(.headline)
                    Text(device.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                reloadButton
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            TextField("搜索名称、拼音首字母或包名", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private var reloadButton: some View {
        Button {
            store.load(device, reload: true)
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(store.loading.contains(device.id))
        .help("重新读取应用列表")
    }

    private var footer: some View {
        HStack {
            if let error = store.errors[device.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("打开") { openSelected() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(target == nil)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if apps.isEmpty && store.loading.contains(device.id) {
            // Skeleton rows in the shape of the list, until it is read.
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBlock(width: 40, height: 11).padding(.bottom, 10)
                ForEach(0..<8, id: \.self) { index in
                    HStack(spacing: 10) {
                        SkeletonBlock(width: 28, height: 28, radius: 7)
                        VStack(alignment: .leading, spacing: 5) {
                            SkeletonBlock(width: CGFloat([90, 120, 70, 110][index % 4]), height: 11)
                            SkeletonBlock(width: CGFloat([150, 180, 130, 170][index % 4]), height: 9)
                        }
                    }
                    .padding(.vertical, 7)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if filtered.isEmpty {
            Text(apps.isEmpty ? "没有读取到应用" : "没有匹配的应用")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                let recents = searching ? [] : recentApps
                let stripRecents = Array(recents.prefix(8))
                List(selection: $selection) {
                    // Group titles are plain rows, not section headers: a header
                    // reaching the top would float on a bar, and look unlike
                    // the others.
                    if !stripRecents.isEmpty {
                        groupTitle("最近", first: true)
                        recentsStrip(stripRecents)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                    let shown = Set(stripRecents.map(\.package))
                    let rest = filtered.filter { !shown.contains($0.package) }
                    if searching {
                        // One list in match order: best matches on top.
                        groupTitle("搜索结果", first: true)
                        ForEach(rest) { row($0) }
                    }
                    let installed = searching ? [] : rest.filter { !$0.system }
                    let system = searching ? [] : rest.filter(\.system)
                    if !installed.isEmpty {
                        groupTitle("已安装", first: stripRecents.isEmpty)
                        ForEach(installed) { row($0) }
                    }
                    if !system.isEmpty {
                        groupTitle("系统应用", first: stripRecents.isEmpty && installed.isEmpty)
                        ForEach(system) { row($0) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Double-click (or Return on a row) opens it, as in Finder.
                .contextMenu(forSelectionType: String.self) { _ in
                    EmptyView()
                } primaryAction: { packages in
                    selection = packages.first
                    openSelected()
                }
            }
        }
    }

    /// A group's title, as a row of its own (see the list above).
    private func groupTitle(_ text: String, first: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? 4 : 14)
            .padding(.bottom, 2)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    /// Recently opened apps as a row of larger icons, newest first; it
    /// scrolls sideways when they don't all fit.
    private func recentsStrip(_ recents: [DeviceApp]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recents) { app in
                    recentTile(app)
                }
            }
        }
    }

    private func recentTile(_ app: DeviceApp) -> some View {
        let isSelected = selection == app.package
        return VStack(spacing: 6) {
            appIcon(for: app, size: 46, radius: 11)
                .overlay(alignment: .topTrailing) {
                    if store.open[device.id]?.contains(app.package) == true {
                        Circle()
                            .fill(Theme.online)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                            .offset(x: 2, y: -2)
                    }
                }
            Text(app.label)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Theme.accent : .primary)
        }
        .frame(width: 68)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selection = app.package
            openSelected()
        }
        .simultaneousGesture(TapGesture(count: 1).onEnded { selection = app.package })
        .help("\(app.label)（双击直接打开）")
    }

    @ViewBuilder
    private func appIcon(for app: DeviceApp, size: CGFloat, radius: CGFloat) -> some View {
        Group {
            if let icon = store.icons[device.id]?[app.package] {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Text(String(app.label.prefix(1)))
                            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
    }

    private func row(_ app: DeviceApp) -> some View {
        HStack(spacing: 10) {
            appIcon(for: app, size: 28, radius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.label).lineLimit(1)
                Text(app.package)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if store.open[device.id]?.contains(app.package) == true {
                Chip(text: "已打开", symbol: "macwindow", tint: Theme.accent)
            }
        }
        .padding(.vertical, 2)
        .tag(app.package)
    }

    /// What Return or “打开” opens: the selected app if it is in the list now
    /// shown; while searching with nothing shown selected, the best match.
    private var target: DeviceApp? {
        let shown = filtered
        if let selection, let app = shown.first(where: { $0.package == selection }) { return app }
        return searching ? shown.first : nil
    }

    private func openSelected() {
        guard let app = target else { return }
        store.openWindow(for: app, on: device, options: options)
        dismiss()
    }
}
