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
            HStack(spacing: 10) {
                IconTile(symbol: "macwindow.on.rectangle", size: 30, style: .tinted(Theme.accent))
                VStack(alignment: .leading, spacing: 1) {
                    Text("在独立窗口中打开应用").font(.headline)
                    Text(device.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.load(device, reload: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.loading.contains(device.id))
                .help("重新读取应用列表")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            TextField("搜索名称、拼音首字母或包名", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16).padding(.bottom, 10)

            Divider()
            content
            Divider()

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
        .frame(width: 460, height: 540)
        .onAppear { store.load(device) }
    }

    @ViewBuilder
    private var content: some View {
        if apps.isEmpty && store.loading.contains(device.id) {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在读取应用…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text(apps.isEmpty ? "没有读取到应用" : "没有匹配的应用")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                let recents = searching ? [] : recentApps
                let shown = Set(recents.map(\.package))
                let rest = filtered.filter { !shown.contains($0.package) }
                if searching {
                    // One list in match order: best matches on top.
                    Section("搜索结果") { ForEach(rest) { row($0) } }
                }
                let installed = searching ? [] : rest.filter { !$0.system }
                let system = searching ? [] : rest.filter(\.system)
                if !recents.isEmpty {
                    Section("最近") { ForEach(recents) { row($0) } }
                }
                if !installed.isEmpty {
                    Section("已安装") { ForEach(installed) { row($0) } }
                }
                if !system.isEmpty {
                    Section("系统应用") { ForEach(system) { row($0) } }
                }
            }
            .listStyle(.inset)
            // Double-click (or Return on a row) opens it, as in Finder.
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { packages in
                selection = packages.first
                openSelected()
            }
        }
    }

    private func row(_ app: DeviceApp) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = store.icons[device.id]?[app.package] {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    // While icons load (or for an app without one).
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 28, height: 28)
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
