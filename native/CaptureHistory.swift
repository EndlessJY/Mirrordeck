import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Screenshots, recordings and animations saved by this app, newest first,
/// so they can be found again (and dragged into a chat) after the notice in
/// the mirror window has gone.
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()
    private static let key = "capture.history"
    private static let limit = 40

    @Published private(set) var items: [URL] = []

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
        prune()
    }

    func add(_ url: URL) {
        let run = {
            self.items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
            self.items.insert(url, at: 0)
            if self.items.count > Self.limit { self.items.removeLast(self.items.count - Self.limit) }
            self.save()
        }
        Thread.isMainThread ? run() : DispatchQueue.main.async(execute: run)
    }

    /// Drops files that were moved or deleted since.
    func prune() {
        let kept = items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if kept != items {
            items = kept
            save()
        }
    }

    func moveToTrash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, _ in
            DispatchQueue.main.async {
                self.items.removeAll { $0 == url }
                self.save()
            }
        }
    }

    private func save() {
        UserDefaults.standard.set(items.map(\.path), forKey: Self.key)
    }

    static func copy(_ url: URL) {
        _ = MirrorStore.copyToClipboard(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The grid of recent captures: drag one out into a chat or a document,
/// double-click to open it, right-click for copy, Finder and trash.
struct CaptureHistoryView: View {
    @ObservedObject private var history = CaptureHistory.shared
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 132), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近捕获").font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.open(DeviceActions.saveDirectoryURL(
                        UserDefaults.standard.string(forKey: DeviceActions.directoryKey) ?? ""))
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if history.items.isEmpty {
                Text("截图、录屏和动图保存后会出现在这里，可以直接拖进聊天窗口。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(history.items, id: \.self) { url in
                            CaptureTile(url: url)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 420)
                Text("拖动到其他应用即可发送，双击打开，右键更多操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .secondaryPanelSize(width: 460)
        .onAppear { history.prune() }
    }
}

private struct CaptureTile: View {
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var isVideo: Bool {
        ["mp4", "mkv", "mov"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(height: 112)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.accent.opacity(hovering ? 0.6 : 0), lineWidth: 1.5))
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(url.lastPathComponent)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("拷贝") { CaptureHistory.copy(url) }
            Button("打开") { NSWorkspace.shared.open(url) }
            Button("在访达中显示") { CaptureHistory.reveal(url) }
            Divider()
            Button("移到废纸篓") { CaptureHistory.shared.moveToTrash(url) }
        }
        .task(id: url) { thumbnail = await Self.thumbnail(for: url) }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 240, height: 240),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
