import Foundation

/// Turns a recording into an animated WebP: about a third of the GIF size for
/// the same picture, plays automatically wherever images do (browsers, GitHub,
/// Feishu chats and documents).
///
/// Frames come from the same sequential reader as the GIF. Unchanged frames
/// are skipped (their time extends the previous frame); libwebp then encodes
/// only the changed rectangle of each frame, lossy at the chosen quality.
enum WebPConverter {
    static func convert(video: URL, to destination: URL,
                        options: GIFOptions = GIFOptions()) throws {
        let source = try FrameSource(video: video, options: options)
        let width = source.width, height = source.height

        var animOptions = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&animOptions) != 0 else { throw Failure.encoder }
        animOptions.anim_params.loop_count = 0
        // Every frame after the first carries only what changed; trying
        // keyframes or lossless candidates as well doubles the time for
        // almost no saving on screen recordings.
        animOptions.allow_mixed = 0
        animOptions.kmin = 0
        animOptions.kmax = 0
        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &animOptions) else {
            throw Failure.encoder
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw Failure.encoder }
        config.quality = Float(options.webpQuality)
        // Method 2 is about twice as fast as the default 4 at the same size.
        config.method = 2
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else { throw Failure.encoder }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw Failure.encoder }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = 1
        defer { WebPPictureFree(&picture) }

        var previous: [UInt8]?
        var lastTime = 0.0
        var added = 0
        while let (pixels, time) = source.next() {
            lastTime = time
            if let previous, nearlyEqual(previous, pixels) { continue }
            let ok = pixels.withUnsafeBufferPointer { buffer -> Int32 in
                WebPPictureImportBGRA(&picture, buffer.baseAddress, Int32(width * 4))
            }
            guard ok != 0 else { throw Failure.encoder }
            let stamp = Int32((time * 1000).rounded())
            guard WebPAnimEncoderAdd(encoder, &picture, stamp, &config) != 0 else {
                throw Failure.encoder
            }
            previous = pixels
            added += 1
        }
        try source.finish()
        guard added > 0 else { throw GIFConverter.Failure.invalidVideo }
        // The last frame lasts until the end of the recording.
        let end = max(lastTime + 1 / Double(source.fps), source.videoEnd)
        guard WebPAnimEncoderAdd(encoder, nil, Int32((end * 1000).rounded()), nil) != 0 else {
            throw Failure.encoder
        }
        var data = WebPData()
        WebPDataInit(&data)
        defer { WebPDataClear(&data) }
        guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else {
            throw Failure.encoder
        }

        // Written beside the system temp files and moved into place when complete.
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanadb-gif-\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: partial) }
        try Data(bytes: bytes, count: data.size).write(to: partial)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Frames that differ only by video noise count as unchanged.
    private static func nearlyEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in
                var index = 0
                let count = min(x.count, y.count)
                while index < count {
                    if abs(Int(x[index]) - Int(y[index])) > 6 { return false }
                    index += 1
                }
                return true
            }
        }
    }

    enum Failure: LocalizedError {
        case encoder
        var errorDescription: String? { "WebP 编码失败。" }
    }
}
