import AppKit
import AVFoundation
import CoreImage
import CoreMediaIO
import SwiftUI

/// iPhone / iPad screens over USB. macOS exposes a trusted, unlocked device as
/// a capture device (the one QuickTime records from); the window shows it and
/// captures screenshots, recordings and GIFs from it. There is no control of
/// the device: iOS offers no input channel for this.
final class IOSMirrorStore: ObservableObject {
    static let shared = IOSMirrorStore()

    @Published private(set) var open = Set<String>()
    @Published private(set) var starting = Set<String>()
    @Published private(set) var savingCount = 0
    @Published var errors: [String: String] = [:]
    private var windows: [String: IOSMirrorWindow] = [:]
    /// Devices whose window closed because they were unplugged, by name: the
    /// "已断开" notice goes away when that iPhone is connected again.
    private var unplugged: [String: String] = [:]
    private var connectObserver: NSObjectProtocol?

    fileprivate func beginSaving() {
        DispatchQueue.main.async { self.savingCount += 1 }
    }

    fileprivate func endSaving() {
        DispatchQueue.main.async { self.savingCount = max(0, self.savingCount - 1) }
    }

    private init() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice,
                  device.modelID == "iOS Device" else { return }
            for (id, name) in self.unplugged where name == device.localizedName {
                self.unplugged.removeValue(forKey: id)
                self.errors[id] = nil
            }
        }
    }

    /// Lets iOS devices appear as capture devices. Done at launch: a device
    /// shows up about a second later.
    static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    func start(device: ADBDevice) {
        let id = device.identity
        if let window = windows[id] {
            window.bringForward()
            return
        }
        guard !starting.contains(id) else { return }
        starting.insert(id)
        errors[id] = nil
        Self.enableScreenCaptureDevices()
        Self.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.starting.remove(id)
                self.errors[id] = "需要相机权限才能显示 iPhone 画面：请在“系统设置 › 隐私与安全性 › 相机”中允许幕台。"
                return
            }
            Self.findCaptureDevice(named: device.marketName ?? "") { capture, duplicate in
                self.starting.remove(id)
                guard let capture else {
                    self.errors[id] = duplicate ?
                        "连接了多台名为“\(device.title)”的设备，无法区分。请在其中一台的“设置 › 通用 › 关于本机 › 名称”中改名后重试。" :
                        "没有找到这台 iPhone 的画面。请解锁 iPhone，确认已点“信任”，必要时重新插拔数据线。"
                    return
                }
                let window = IOSMirrorWindow(device: device, capture: capture) { [weak self] message in
                    self?.windows.removeValue(forKey: id)
                    self?.open.remove(id)
                    if let message {
                        self?.errors[id] = message
                        self?.unplugged[id] = device.marketName ?? ""
                    }
                }
                if let failure = window.startCapture() {
                    self.errors[id] = failure
                    return
                }
                self.windows[id] = window
                self.open.insert(id)
            }
        }
    }

    func stop(deviceID: String) {
        windows[deviceID]?.close()
    }

    /// A window is open, starting, or still saving its recording.
    var hasActiveWork: Bool { !windows.isEmpty || !starting.isEmpty || savingCount > 0 }

    func stopAll() {
        windows.values.forEach { $0.close() }
    }

    private static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        // Sound from the device is optional; the picture needs the camera grant.
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// The device's capture device appears up to a few seconds after the
    /// screen-capture switch is turned on.
    /// Matched by the device name, the one link macOS gives between a capture
    /// device and the iPhone (its unique ID is a random UUID, not the UDID).
    /// Two connected iPhones with the same name cannot be told apart, so that
    /// is reported rather than guessed.
    private static func findCaptureDevice(named name: String, attempts: Int = 24,
                                          completion: @escaping (AVCaptureDevice?, Bool) -> Void) {
        let named = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                                     position: .unspecified).devices
            .filter { $0.modelID == "iOS Device" && $0.localizedName == name }
        if named.count > 1 {
            completion(nil, true)
            return
        }
        if let match = named.first {
            completion(match, false)
            return
        }
        if attempts <= 0 {
            completion(nil, false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            findCaptureDevice(named: name, attempts: attempts - 1, completion: completion)
        }
    }
}

/// What the window's title bar and overlay show.
final class IOSMirrorModel: ObservableObject {
    @Published var pinned = false
    @Published var audioAllowed = true
    @Published var audioOn = false
    @Published var captureKind: String?        // "record" or "gif"
    @Published var countdown = 0
    @Published var recordingStarted: Date?
    @Published var busy: String?
    @Published var notice: String?
    @Published var noticeIsError = false
    @Published var flash = false
    @Published var screenshotSaving = false
}

final class IOSMirrorWindow: NSObject, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureFileOutputRecordingDelegate {
    let device: ADBDevice
    private var capture: AVCaptureDevice
    private let onClose: (String?) -> Void
    private let model = IOSMirrorModel()
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioPreview = AVCaptureAudioPreviewOutput()
    private let ciContext = CIContext()
    private let frameQueue = DispatchQueue(label: "uk.agpt.lanadbmanager.ios.frames")
    private let sessionQueue = DispatchQueue(label: "uk.agpt.lanadbmanager.ios.session")
    private var latestFrame: CVPixelBuffer?
    private var window: NSWindow?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var frameSize = CGSize.zero
    private var closing = false
    private var disconnectObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var countdownTimer: Timer?
    private var recordingSource: URL?
    private var recordingDestination: URL?
    private var recordingKind = "record"
    private var recordingIncludesAudio = false
    /// Keeps the window object alive while a recording finishes after close.
    private var keepAlive: IOSMirrorWindow?

    init(device: ADBDevice, capture: AVCaptureDevice, onClose: @escaping (String?) -> Void) {
        self.device = device
        self.capture = capture
        self.onClose = onClose
        super.init()
    }

    /// nil when the picture is starting; otherwise why it cannot.
    func startCapture() -> String? {
        do {
            let input = try AVCaptureDeviceInput(device: capture)
            guard session.canAddInput(input) else { return "这台 iPhone 的画面正被其他应用使用（如 QuickTime），请先关闭后再试。" }
            session.addInput(input)
        } catch {
            return "无法打开 iPhone 画面：\(error.localizedDescription)"
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        let audioAllowed = UserDefaults.standard.object(forKey: "mirror.audio") as? Bool ?? true
        model.audioAllowed = audioAllowed
        audioPreview.volume = 0
        if session.canAddOutput(audioPreview) { session.addOutput(audioPreview) }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let allowed = UserDefaults.standard.object(forKey: "mirror.audio") as? Bool ?? true
            if self.model.audioAllowed != allowed {
                self.model.audioAllowed = allowed
                if !allowed, self.model.audioOn {
                    self.model.audioOn = false
                    self.audioPreview.volume = 0
                }
            }
        }
        makeWindow()
        watchDisconnect()
        sessionQueue.async { [session] in session.startRunning() }
        return nil
    }

    /// The capture device also goes away for a moment when the iPhone turns
    /// between portrait and landscape: it comes back (same unique ID) within a
    /// second or two, and the picture continues. Only when it stays away (the
    /// cable was pulled) does the window close.
    private func watchDisconnect() {
        if let observer = disconnectObserver { NotificationCenter.default.removeObserver(observer) }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: capture, queue: .main) { [weak self] _ in
            self?.reconnect(uniqueID: self?.capture.uniqueID ?? "", attempts: 24)
        }
    }

    private func reconnect(uniqueID: String, attempts: Int) {
        guard !closing else { return }
        let back = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                                    position: .unspecified).devices
            .first { $0.uniqueID == uniqueID && $0.isConnected }
        guard let back else {
            if attempts <= 0 {
                finish(message: "\(device.title) 已断开。")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.reconnect(uniqueID: uniqueID, attempts: attempts - 1)
                }
            }
            return
        }
        // If the exact same capture device re-attached while a recording is still
        // running, keep the existing input attached so the recording is not cut.
        let keepExistingInput = movieOutput.isRecording && session.inputs.contains {
            ($0 as? AVCaptureDeviceInput)?.device === back
        }
        if keepExistingInput {
            capture = back
            watchDisconnect()
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: back) else {
            finish(message: "\(device.title) 已断开。")
            return
        }
        capture = back
        watchDisconnect()
        sessionQueue.async { [session] in
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    func bringForward() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.performClose(nil)
    }

    // MARK: Window

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = device.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .black
        window.minSize = NSSize(width: 280, height: 400)

        let content = NSView(frame: window.contentLayoutRect)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        previewLayer = preview
        preview.videoGravity = .resizeAspect
        preview.frame = content.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(preview)
        let overlay = NSHostingView(rootView: IOSMirrorOverlay(model: model, stop: { [weak self] in
            self?.toggleCapture(self?.model.captureKind ?? "record")
        }))
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        window.contentView = content

        let toolbar = NSTitlebarAccessoryViewController()
        toolbar.layoutAttribute = .bottom
        // As in the Android window: the first tool sits under the close button.
        var leading: CGFloat = 3
        if let close = window.standardWindowButton(.closeButton) {
            leading = max(0, close.convert(NSPoint(x: close.bounds.midX, y: 0), to: nil).x - 13.5)
        }
        let bar = NSHostingView(rootView: IOSMirrorToolbar(
            model: model, leading: leading,
            pin: { [weak self] in self?.togglePin() },
            sound: { [weak self] in self?.toggleSound() },
            screenshot: { [weak self] in self?.screenshot() },
            record: { [weak self] in self?.toggleCapture("record") },
            gif: { [weak self] in self?.toggleCapture("gif") }))
        bar.frame = NSRect(x: 0, y: 0, width: 360, height: 27)
        toolbar.view = bar
        window.addTitlebarAccessoryViewController(toolbar)
        // Set again once added, as the Android window does: the bar is then
        // exactly 27 points instead of AppKit's taller default.
        bar.frame = NSRect(x: 0, y: 0, width: 360, height: 27)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Sized like the Android mirror window (scrcpy): the picture scaled to
    /// fit the primary screen's usable area less a 96-point margin, with the
    /// title bar and tools above it. Resizing keeps the device's proportions,
    /// so there are no black bars.
    private func fitWindow(width: Int, height: Int, keepPlace: Bool = false) {
        guard let window, let content = window.contentView, width > 0, height > 0 else { return }
        let ratio = CGFloat(width) / CGFloat(height)
        let screen = NSScreen.screens.first?.visibleFrame ?? window.screen?.visibleFrame ?? .zero
        let bounds = NSSize(width: max(0, screen.width - 96), height: max(0, screen.height - 96))
        var picture = NSSize(width: min(CGFloat(width), bounds.width),
                             height: min(CGFloat(height), bounds.height))
        if picture.width / picture.height > ratio {
            picture.width = (picture.height * ratio).rounded(.down)
        } else {
            picture.height = (picture.width / ratio).rounded(.down)
        }
        let chrome = window.frame.height - content.frame.height   // title bar + tools
        let outer = NSSize(width: picture.width, height: picture.height + chrome)
        window.contentAspectRatio = NSSize(width: width, height: height)
        // First frame: centred on the screen. On rotation: about the window's
        // own centre, kept on the screen.
        let centre = keepPlace ? NSPoint(x: window.frame.midX, y: window.frame.midY) :
            NSPoint(x: screen.midX, y: screen.midY)
        var origin = NSPoint(x: (centre.x - outer.width / 2).rounded(),
                             y: (centre.y - outer.height / 2).rounded())
        origin.x = min(max(origin.x, screen.minX), screen.maxX - outer.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - outer.height)
        window.setFrame(NSRect(origin: origin, size: outer), display: true, animate: keepPlace)
    }

    func windowWillClose(_ notification: Notification) {
        finish(message: nil)
    }

    private var closeMessage: String?

    private func finish(message: String?) {
        guard !closing else { return }
        closing = true
        closeMessage = message
        countdownTimer?.invalidate()
        if let observer = disconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            disconnectObserver = nil
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        // Stays alive until the capture is fully torn down: releasing the
        // window and its preview while the session is still stopping on its
        // queue blocks the main thread.
        keepAlive = self
        if message != nil { window?.close() }
        if movieOutput.isRecording {
            // The recording is finished and saved, then the session stops.
            movieOutput.stopRecording()
        } else {
            tearDown()
        }
    }

    /// Stops the session off the main thread, then detaches the preview and
    /// lets the store forget this window.
    private func tearDown() {
        let message = closeMessage
        frameQueue.async { [weak self] in self?.latestFrame = nil }
        sessionQueue.async { [weak self, session] in
            session.stopRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
                self.previewLayer?.session = nil
                self.previewLayer = nil
                self.window?.contentView = nil
                self.onClose(message)
                self.keepAlive = nil
            }
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestFrame = frame
        // Sized on the first frame, and again when the device turns between
        // portrait and landscape.
        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        if size != frameSize {
            let first = frameSize == .zero
            frameSize = size
            DispatchQueue.main.async { [weak self] in
                self?.fitWindow(width: Int(size.width), height: Int(size.height), keepPlace: !first)
            }
        }
    }

    // MARK: Title bar actions

    private func togglePin() {
        model.pinned.toggle()
        window?.level = model.pinned ? .floating : .normal
    }

    private func toggleSound() {
        guard model.audioAllowed else { return }
        model.audioOn.toggle()
        audioPreview.volume = model.audioOn ? 1 : 0
    }

    private func screenshot() {
        guard !model.screenshotSaving else { return }
        var frame: CVPixelBuffer?
        frameQueue.sync { frame = latestFrame }
        guard let frame else {
            showNotice("画面尚未就绪", error: true)
            return
        }
        model.screenshotSaving = true
        withAnimation(.easeOut(duration: 0.06)) { model.flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            withAnimation(.easeOut(duration: 0.32)) { self?.model.flash = false }
        }
        let device = device
        let context = ciContext
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = CIImage(cvPixelBuffer: frame)
            let saved: URL? = {
                guard let picture = context.createCGImage(image, from: image.extent),
                      let destination = DeviceActions.destination(for: device, kind: "截图",
                                                                   extension: "png"),
                      let data = NSBitmapImageRep(cgImage: picture)
                          .representation(using: .png, properties: [:]),
                      (try? data.write(to: destination)) != nil else { return nil }
                return destination
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.screenshotSaving = false
                if let saved { self.delivered(saved) } else { self.showNotice("截图失败", error: true) }
            }
        }
    }

    /// Record and GIF: a 3-second countdown, then recording; pressing again
    /// (or the pill) stops it.
    private func toggleCapture(_ kind: String) {
        if model.countdown > 0 {
            countdownTimer?.invalidate()
            model.countdown = 0
            model.captureKind = nil
            return
        }
        if movieOutput.isRecording {
            guard model.captureKind == kind else { return }
            model.busy = kind == "gif" ? "正在生成 GIF…" : "正在保存…"
            model.recordingStarted = nil
            movieOutput.stopRecording()
            return
        }
        guard model.captureKind == nil, model.busy == nil else { return }
        model.captureKind = kind
        model.countdown = 3
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.model.countdown -= 1
            if self.model.countdown <= 0 {
                timer.invalidate()
                self.beginRecording(kind)
            }
        }
    }

    private func beginRecording(_ kind: String) {
        let isGIF = kind == "gif"
        guard let destination = isGIF ? DeviceActions.gifDestination(for: device) :
                DeviceActions.destination(for: device, kind: "录屏", extension: "mp4") else {
            model.captureKind = nil
            showNotice("保存位置无法写入", error: true)
            return
        }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanadb-ios-\(UUID().uuidString).mov")
        // H.265 when a dedicated video connection supports it (.muxed connections
        // carry their own compressed stream and are remuxed below).
        if let connection = movieOutput.connection(with: .video), connection.isActive {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
        let includeAudio = !isGIF && RecordingSettings.recordsAudio
        movieOutput.connection(with: .audio)?.isEnabled = includeAudio
        recordingSource = source
        recordingDestination = destination
        recordingKind = kind
        recordingIncludesAudio = includeAudio
        movieOutput.startRecording(to: source, recordingDelegate: self)
        model.recordingStarted = Date()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let kind = recordingKind
        let destination = recordingDestination
        let includeAudio = recordingIncludesAudio
        // AVFoundation reports a stop or device rotation disconnect with
        // AVErrorRecordingSuccessfullyFinishedKey = true when the file is intact.
        let usable = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        IOSMirrorStore.shared.beginSaving()
        let finished: (URL?) -> Void = { [weak self] saved in
            try? FileManager.default.removeItem(at: outputFileURL)
            IOSMirrorStore.shared.endSaving()
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.busy = nil
                self.model.captureKind = nil
                self.model.recordingStarted = nil
                if let saved { self.delivered(saved) } else { self.showNotice("录制失败", error: true) }
                if self.closing { self.tearDown() }
            }
        }
        guard usable, let destination else { finished(nil); return }
        DispatchQueue.main.async { [weak self] in
            self?.model.busy = kind == "gif" ? "正在生成 GIF…" : "正在保存…"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if kind == "gif" {
                do {
                    let options = RecordingSettings.gif()
                    if destination.pathExtension == "webp" {
                        try WebPConverter.convert(video: outputFileURL, to: destination, options: options)
                    } else {
                        try GIFConverter.convert(video: outputFileURL, to: destination, options: options)
                    }
                    finished(destination)
                } catch {
                    finished(nil)
                }
                return
            }
            Self.exportMP4(from: outputFileURL, to: destination, includeAudio: includeAudio) { ok in
                finished(ok ? destination : nil)
            }
        }
    }

    private struct TrackMetadata {
        let videoTrack: AVAssetTrack
        let formatHint: CMFormatDescription?
        let preferredTransform: CGAffineTransform
        let videoTimeRange: CMTimeRange
        let audioTrack: AVAssetTrack?
        let audioTimeRange: CMTimeRange?
    }

    /// Converts the captured `.mov` into `.mp4`: passes H.264/HEVC video packets
    /// straight through without re-encoding and encodes LPCM audio to AAC (since
    /// `.mp4` rejects uncompressed LPCM), falling back to `AVAssetExportSession`
    /// if the source video codec requires transcoding.
    private static func exportMP4(from source: URL, to destination: URL, includeAudio: Bool,
                                  completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: destination)
            let asset = AVURLAsset(url: source)
            guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first,
                  let descriptions = try? await videoTrack.load(.formatDescriptions),
                  let transform = try? await videoTrack.load(.preferredTransform),
                  let videoRange = try? await videoTrack.load(.timeRange) else {
                completion(false)
                return
            }
            var audioTrack: AVAssetTrack?
            var audioRange: CMTimeRange?
            if includeAudio,
               let track = (try? await asset.loadTracks(withMediaType: .audio))?.first,
               let range = try? await track.load(.timeRange) {
                audioTrack = track
                audioRange = range
            }
            let meta = TrackMetadata(
                videoTrack: videoTrack,
                formatHint: descriptions.first,
                preferredTransform: transform,
                videoTimeRange: videoRange,
                audioTrack: audioTrack,
                audioTimeRange: audioRange
            )
            let subType = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }
            let canPassthroughVideo = subType == kCMVideoCodecType_HEVC || subType == kCMVideoCodecType_H264
            if canPassthroughVideo, remuxVideoPassthrough(asset: asset, meta: meta,
                                                          to: destination, completion: completion) {
                return
            }
            exportTranscoded(meta: meta, to: destination, completion: completion)
        }
    }

    private static func remuxVideoPassthrough(asset: AVAsset, meta: TrackMetadata,
                                              to destination: URL,
                                              completion: @escaping (Bool) -> Void) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: destination, fileType: .mp4) else {
            return false
        }
        writer.shouldOptimizeForNetworkUse = true
        let videoOut = AVAssetReaderTrackOutput(track: meta.videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: meta.formatHint)
        videoIn.transform = meta.preferredTransform
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { return false }
        reader.add(videoOut)
        writer.add(videoIn)

        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack = meta.audioTrack {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            audioOut.alwaysCopiesSampleData = false
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            if reader.canAdd(audioOut), writer.canAdd(audioIn) {
                reader.add(audioOut)
                writer.add(audioIn)
                audioPair = (audioOut, audioIn)
            }
        }

        guard writer.startWriting(), reader.startReading() else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "uk.agpt.lanadbmanager.ios.remux.video")
        group.enter()
        var videoFinished = false
        videoIn.requestMediaDataWhenReady(on: videoQueue) {
            while videoIn.isReadyForMoreMediaData, !videoFinished {
                var ended = false
                autoreleasepool {
                    if let sample = videoOut.copyNextSampleBuffer() {
                        if !videoIn.append(sample) { ended = true }
                    } else {
                        ended = true
                    }
                }
                if ended {
                    videoFinished = true
                    videoIn.markAsFinished()
                    group.leave()
                }
            }
        }

        if let (audioOut, audioIn) = audioPair {
            let audioQueue = DispatchQueue(label: "uk.agpt.lanadbmanager.ios.remux.audio")
            group.enter()
            var audioFinished = false
            audioIn.requestMediaDataWhenReady(on: audioQueue) {
                while audioIn.isReadyForMoreMediaData, !audioFinished {
                    var ended = false
                    autoreleasepool {
                        if let sample = audioOut.copyNextSampleBuffer() {
                            if !audioIn.append(sample) { ended = true }
                        } else {
                            ended = true
                        }
                    }
                    if ended {
                        audioFinished = true
                        audioIn.markAsFinished()
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            if reader.status == .failed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
                exportTranscoded(meta: meta, to: destination, completion: completion)
                return
            }
            writer.finishWriting {
                if writer.status == .completed {
                    completion(true)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    exportTranscoded(meta: meta, to: destination, completion: completion)
                }
            }
        }
        return true
    }

    private static func exportTranscoded(meta: TrackMetadata, to destination: URL,
                                         completion: @escaping (Bool) -> Void) {
        try? FileManager.default.removeItem(at: destination)
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? compVideo.insertTimeRange(meta.videoTimeRange, of: meta.videoTrack, at: .zero)) != nil else {
            completion(false)
            return
        }
        compVideo.preferredTransform = meta.preferredTransform
        if let audioTrack = meta.audioTrack, let audioRange = meta.audioTimeRange,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            completion(false)
            return
        }
        export.outputURL = destination
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            completion(export.status == .completed)
        }
    }

    /// Saved: the thumbnail shrinks into the corner, and the file is copied
    /// and revealed as the settings say, as in the Android window.
    private func delivered(_ url: URL) {
        let copy = UserDefaults.standard.object(forKey: MirrorStore.copyToClipboardKey) as? Bool ?? true
        let reveal = UserDefaults.standard.object(forKey: MirrorStore.revealInFinderKey) as? Bool ?? false
        let copied = copy && MirrorStore.copyToClipboard(url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let still = Self.still(of: url)
            DispatchQueue.main.async {
                guard let self else { return }
                if let still { self.showThumbnail(still, file: url) }
                self.showNotice(copied ? "已复制到剪贴板" : "已保存", error: false)
                if reveal { Self.reveal(url) }
            }
        }
    }

    /// The image for the thumbnail: the picture itself, the first frame of a
    /// GIF / WebP, or a frame of a recording.
    private static func still(of url: URL) -> NSImage? {
        if url.pathExtension.lowercased() != "mp4" { return NSImage(contentsOf: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        guard let frame = try? generator.copyCGImage(at: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                     actualTime: nil) else { return nil }
        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }

    /// `open -R` brings Finder forward even when this app cannot activate it.
    private static func reveal(_ url: URL) {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-R", url.path]
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        if (try? opener.run()) == nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// The Android window's thumbnail: from the full picture into the lower
    /// right corner (30% of the width, 14-point margin, white border), rests
    /// 1.2 s, then slides out to the right. Clicking it shows the file.
    private func showThumbnail(_ image: NSImage, file: URL) {
        guard !closing, let content = window?.contentView,
              image.size.width > 0, image.size.height > 0 else { return }
        let bounds = content.bounds
        let aspect = image.size.width / image.size.height
        var full = bounds
        if bounds.width / bounds.height > aspect {
            full.size.width = bounds.height * aspect
            full.origin.x = bounds.midX - full.width / 2
        } else {
            full.size.height = bounds.width / aspect
            full.origin.y = bounds.midY - full.height / 2
        }
        let margin: CGFloat = 14
        let width = max(72, (bounds.width * 0.3).rounded())
        let height = (width / aspect).rounded()
        let corner = NSRect(x: bounds.maxX - width - margin, y: bounds.minY + margin,
                            width: width, height: height)

        let card = IOSThumbnailView(frame: full)
        card.toolTip = "在访达中显示"
        card.onClick = { [weak card] in
            Self.reveal(file)
            card?.removeFromSuperview()
        }
        card.wantsLayer = true
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 10
        card.layer?.shadowOffset = CGSize(width: 0, height: -3)
        let picture = NSImageView(image: image)
        picture.frame = card.bounds
        picture.autoresizingMask = [.width, .height]
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 4
        picture.layer?.masksToBounds = true
        picture.layer?.borderColor = NSColor.white.cgColor
        picture.layer?.borderWidth = 0
        card.addSubview(picture)
        content.addSubview(card, positioned: .above, relativeTo: nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.42
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            card.animator().frame = corner
            picture.layer?.cornerRadius = 10
            picture.layer?.borderWidth = 2.5
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard card.superview != nil else { return }
                var away = corner
                away.origin.x = content.bounds.maxX + 8
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    card.animator().frame = away
                    card.animator().alphaValue = 0
                }, completionHandler: { card.removeFromSuperview() })
            }
        })
    }

    private func showNotice(_ text: String, error: Bool) {
        model.noticeIsError = error
        withAnimation(.easeOut(duration: 0.2)) { model.notice = text }
        // As in the Android window: 1.6 s for a result, 2.6 s for a failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 2.6 : 1.6)) { [weak self] in
            guard self?.model.notice == text else { return }
            withAnimation(.easeIn(duration: 0.3)) { self?.model.notice = nil }
        }
    }
}

// MARK: - Title bar and overlay

/// The capture thumbnail; a click anywhere on it shows the file in Finder.
private final class IOSThumbnailView: NSView {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The image view inside would otherwise take the click.
        super.hitTest(point) != nil ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private struct IOSMirrorToolbar: View {
    @ObservedObject var model: IOSMirrorModel
    let leading: CGFloat
    let pin: () -> Void
    let sound: () -> Void
    let screenshot: () -> Void
    let record: () -> Void
    let gif: () -> Void

    var body: some View {
        let recordSelected = model.captureKind == "record"
        let gifSelected = model.captureKind == "gif"
        let recordPending = model.busy != nil && recordSelected
        let gifPending = model.busy != nil && gifSelected
        // The Android window's tool metrics: 27×26 buttons, 31.5-point step,
        // 16-point symbols, a 27-point bar.
        HStack(spacing: 4.5) {
            IOSToolButton(
                help: model.pinned ? "已置顶，点击取消" : "置顶窗口",
                active: model.pinned,
                recording: false,
                enabled: true,
                action: pin
            ) {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 16, weight: .medium))
            }
            IOSToolButton(
                help: !model.audioAllowed ? "未播放设备声音，请在设置中开启" :
                      (model.audioOn ? "关闭声音" : "播放声音"),
                active: model.audioAllowed && model.audioOn,
                recording: false,
                enabled: model.audioAllowed,
                action: sound
            ) {
                Image(systemName: model.audioAllowed && model.audioOn ? "speaker.wave.2.fill" : "speaker.slash")
                    .font(.system(size: 16, weight: .medium))
            }
            IOSToolButton(
                help: model.screenshotSaving ? "正在保存截图" : "保存截图",
                active: false,
                recording: false,
                enabled: !model.screenshotSaving,
                action: screenshot
            ) {
                Image(systemName: model.screenshotSaving ? "hourglass" : "camera")
                    .font(.system(size: 16, weight: .medium))
            }
            IOSToolButton(
                help: recordPending ? "正在处理录屏" :
                      (model.countdown > 0 && recordSelected ? "取消录屏倒计时" :
                      (recordSelected ? "停止录屏" : "开始录屏")),
                active: recordSelected && !recordPending,
                recording: recordSelected && !recordPending,
                enabled: model.busy == nil && (model.captureKind == nil || recordSelected),
                action: record
            ) {
                Image(systemName: recordPending ? "hourglass" :
                      (recordSelected && model.recordingStarted != nil ? "stop.circle.fill" : "record.circle"))
                    .font(.system(size: 16, weight: .medium))
            }
            IOSToolButton(
                help: gifPending ? "正在处理 GIF" :
                      (model.countdown > 0 && gifSelected ? "取消 GIF 倒计时" :
                      (gifSelected ? "停止录制 GIF" : "录制 GIF")),
                active: gifSelected && !gifPending,
                recording: gifSelected && !gifPending,
                enabled: model.busy == nil && (model.captureKind == nil || gifSelected),
                action: gif
            ) {
                if gifPending {
                    Image(systemName: "hourglass").font(.system(size: 16, weight: .medium))
                } else if gifSelected && model.recordingStarted != nil {
                    Image(systemName: "stop.circle.fill").font(.system(size: 16, weight: .medium))
                } else {
                    Text("GIF").font(.system(size: 12, weight: .bold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, leading)
        .padding(.top, 1)
        .frame(height: 27)
    }
}

private struct IOSToolButton<Label: View>: View {
    let help: String
    let active: Bool
    let recording: Bool
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        let tint: Color = !enabled ? Color.secondary.opacity(0.45) :
            (recording ? .red : (active ? Theme.accent : Color.primary.opacity(0.8)))
        let fill: Color = !enabled ? .clear :
            (recording ? Color.red.opacity(0.16) :
             active ? Theme.accent.opacity(0.16) :
             hovered ? Color.primary.opacity(0.08) : .clear)
        Button(action: action) {
            label()
                .frame(width: 27, height: 26)
                .foregroundStyle(tint)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct IOSMirrorOverlay: View {
    @ObservedObject var model: IOSMirrorModel
    let stop: () -> Void
    @State private var blink = false

    var body: some View {
        ZStack {
            if model.countdown > 0 {
                Color.black.opacity(0.42)
                Text("\(model.countdown)")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
                    .id(model.countdown)
                    .transition(.scale(scale: 1.25).combined(with: .opacity))
            }
            if model.flash { Color.white.opacity(0.85) }
            VStack(spacing: 6) {
                statusPill
                if let notice = model.notice {
                    capsule {
                        Image(systemName: model.noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.noticeIsError ? Color.yellow : Color.green)
                        Text(notice)
                    }
                    .transition(.opacity)
                }
                Spacer()
            }
            .padding(.top, 12)
        }
        .animation(.spring(duration: 0.3), value: model.countdown)
    }

    @ViewBuilder
    private var statusPill: some View {
        if let started = model.recordingStarted, let kind = model.captureKind {
            TimelineView(.periodic(from: started, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                capsule {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                        .opacity(blink ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(), value: blink)
                        .onAppear { blink = true }
                        // Reset, so the next recording's dot blinks again.
                        .onDisappear { blink = false }
                    Text("\(kind == "gif" ? "GIF" : "录屏") \(String(format: "%02d:%02d", seconds / 60, seconds % 60))")
                        .monospacedDigit()
                }
            }
            .onTapGesture(perform: stop)
            .help("点按停止录制")
        } else if let busy = model.busy {
            capsule {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text(busy).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 28)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
    }
}
