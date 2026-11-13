import AVFoundation
import CoreVideo
import Foundation

/// GIF output quality chosen in Settings.
struct GIFOptions {
    var maxSide: Int = 960
    var fps: Int = 12
    /// Keep Display P3 colours (and tag the GIF) for wide-gamut devices.
    var displayP3 = false
    /// Largest colour difference (weighted RGB distance) the compressor may
    /// accept to continue a repeated run. Video noise otherwise breaks every
    /// run; small values are invisible and shrink the file a lot. 0 = lossless.
    var lossy = 12
    /// libwebp quality (0–100) for the animated WebP export.
    var webpQuality = 80

    static func preset(_ name: String) -> GIFOptions {
        switch name {
        case "high": return GIFOptions(maxSide: 1280, fps: 15, webpQuality: 85)
        case "small": return GIFOptions(maxSide: 640, fps: 10, webpQuality: 75)
        default: return GIFOptions(maxSide: 960, fps: 12, webpQuality: 80)
        }
    }
}

/// Turns a recording into an animated GIF.
///
/// Frames are read sequentially at the target size and rate (no seeking, which
/// re-decodes from the last keyframe for every frame), identical frames are
/// merged into a longer delay, later frames only carry the rectangle that
/// changed, and each frame gets its own 256-colour palette built from its
/// actual pixels so flat interface colours stay distinct. Quantisation and LZW
/// compression of a batch of frames run in parallel.
enum GIFConverter {
    static func convert(video: URL, to destination: URL,
                        options: GIFOptions = GIFOptions()) throws {
        let source = try FrameSource(video: video, options: options)
        let width = source.width, height = source.height, fps = source.fps
        let videoEnd = source.videoEnd

        // Written beside the system temp files and moved into place when
        // complete, so the save folder never shows a half-written GIF.
        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanadb-gif-\(UUID().uuidString).gif")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let file = try? FileHandle(forWritingTo: partial) else { throw Failure.output }
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: partial)
        }
        file.write(GIFWriter.header(width: width, height: height, displayP3: options.displayP3))

        var reference: [UInt8]?
        var pending: [PendingFrame] = []
        var lastTime = 0.0
        var written = 0
        let batchSize = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)

        func flush(final: Bool) {
            guard !pending.isEmpty else { return }
            // The last pending frame may still grow (merged duplicates) unless final.
            let ready = final ? pending : Array(pending.dropLast())
            guard !ready.isEmpty else { return }
            var encoded = [Data](repeating: Data(), count: ready.count)
            encoded.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: ready.count) { index in
                    slots[index] = GIFWriter.frame(ready[index], width: width,
                                                   lossy: options.lossy)
                }
            }
            encoded.forEach { file.write($0) }
            written += ready.count
            pending = final ? [] : [pending[pending.count - 1]]
        }

        while let (frame, time) = source.next() {
            var pixels = frame
            // Each sample covers the time until the next one.
            if !pending.isEmpty {
                pending[pending.count - 1].end = time
            }
            if reference == nil {
                reference = pixels
                pending.append(PendingFrame(pixels: pixels, rect: (0, 0, width, height),
                                            start: time, end: time))
            } else if let rect = markChanges(&pixels, against: &reference!, width: width,
                                             height: height) {
                pending.append(PendingFrame(pixels: pixels, rect: rect, start: time, end: time))
            }
            // Unchanged frames only extend the previous delay.
            lastTime = time
            if pending.count > batchSize { flush(final: false) }
        }
        try source.finish()
        if !pending.isEmpty {
            pending[pending.count - 1].end = max(lastTime + 1 / Double(fps), videoEnd)
        }
        flush(final: true)
        guard written > 0 else { throw Failure.invalidVideo }
        file.write(Data([0x3B]))
        try file.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    struct PendingFrame {
        /// BGRA; alpha 0 marks a pixel that did not change (drawn transparent).
        let pixels: [UInt8]
        let rect: (x: Int, y: Int, w: Int, h: Int)
        let start: Double
        var end: Double
    }


    /// Compares a frame with what is currently shown. Pixels within a small
    /// tolerance (video compression noise) are marked unchanged (alpha 0); the
    /// others update the shown image. Returns the changed rectangle, or nil.
    private static func markChanges(_ pixels: inout [UInt8], against shown: inout [UInt8],
                                    width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        let tolerance = 10
        var left = width, right = -1, top = -1, bottom = -1
        pixels.withUnsafeMutableBufferPointer { px in
            shown.withUnsafeMutableBufferPointer { ref in
                for y in 0..<height {
                    var i = y * width * 4
                    for x in 0..<width {
                        let db = abs(Int(px[i]) - Int(ref[i]))
                        let dg = abs(Int(px[i + 1]) - Int(ref[i + 1]))
                        let dr = abs(Int(px[i + 2]) - Int(ref[i + 2]))
                        if db <= tolerance && dg <= tolerance && dr <= tolerance {
                            px[i + 3] = 0
                        } else {
                            px[i + 3] = 255
                            ref[i] = px[i]; ref[i + 1] = px[i + 1]; ref[i + 2] = px[i + 2]
                            if x < left { left = x }
                            if x > right { right = x }
                            if top < 0 { top = y }
                            bottom = y
                        }
                        i += 4
                    }
                }
            }
        }
        guard right >= left, top >= 0 else { return nil }
        return (left, top, right - left + 1, bottom - top + 1)
    }

    enum Failure: LocalizedError {
        case invalidVideo, output
        var errorDescription: String? {
            switch self {
            case .invalidVideo: "录制的视频没有有效画面。"
            case .output: "GIF 文件生成失败。"
            }
        }
    }
}

/// Minimal GIF89a writer: per-frame palettes (median cut over a 15-bit
/// histogram) and LZW compression.
private enum GIFWriter {
    static func header(width: Int, height: Int, displayP3: Bool) -> Data {
        var data = Data("GIF89a".utf8)
        data.append(le16(width))
        data.append(le16(height))
        data.append(contentsOf: [0x00, 0x00, 0x00])  // no global colour table
        // Colour profile (ICCRGBG1 application extension, read by browsers
        // and macOS) so the colours match the device.
        let space = CGColorSpace(name: displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        if let icc = space?.copyICCData() as Data? {
            data.append(contentsOf: [0x21, 0xFF, 0x0B])
            data.append(Data("ICCRGBG1012".utf8))
            var offset = 0
            while offset < icc.count {
                let length = min(255, icc.count - offset)
                data.append(UInt8(length))
                data.append(icc.subdata(in: offset..<(offset + length)))
                offset += length
            }
            data.append(0)
        }
        // Loop forever.
        data.append(contentsOf: [0x21, 0xFF, 0x0B])
        data.append(Data("NETSCAPE2.0".utf8))
        data.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        return data
    }

    static func frame(_ frame: GIFConverter.PendingFrame, width: Int, lossy: Int) -> Data {
        let (rx, ry, rw, rh) = frame.rect
        // Gather the rectangle as 15-bit colour keys plus exact sums.
        // Unchanged pixels inside the rectangle are left transparent: long
        // transparent runs compress far better than repainting them.
        let transparentKey: UInt16 = 0xFFFF
        var keys = [UInt16](repeating: 0, count: rw * rh)
        var counts = [Int32](repeating: 0, count: 32768)
        var sums = [Int64](repeating: 0, count: 32768 * 3)
        var usesTransparency = false
        frame.pixels.withUnsafeBufferPointer { px in
          do {
            var k = 0
            for y in ry..<(ry + rh) {
                var i = (y * width + rx) * 4
                for _ in 0..<rw {
                    let b = Int(px[i]), g = Int(px[i + 1]), r = Int(px[i + 2])
                    if px[i + 3] == 0 {
                        keys[k] = transparentKey
                        usesTransparency = true
                        k += 1
                        i += 4
                        continue
                    }
                    let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                    keys[k] = UInt16(key)
                    counts[key] += 1
                    sums[key * 3] += Int64(r)
                    sums[key * 3 + 1] += Int64(g)
                    sums[key * 3 + 2] += Int64(b)
                    k += 1
                    i += 4
                }
            }
          }
        }
        let (palette, lookup, paletteCount) = buildPalette(counts: counts, sums: sums,
                                             maxColors: usesTransparency ? 255 : 256)
        let transparentIndex: UInt8 = 255
        var indices = [UInt8](repeating: 0, count: keys.count)
        for n in 0..<keys.count {
            indices[n] = keys[n] == transparentKey ? transparentIndex : lookup[Int(keys[n])]
        }

        var data = Data()
        // Graphic control: keep the previous frame (disposal 1), delay in 1/100 s.
        let delay = max(2, Int((frame.end * 100).rounded()) - Int((frame.start * 100).rounded()))
        data.append(contentsOf: [0x21, 0xF9, 0x04, usesTransparency ? 0x05 : 0x04])
        data.append(le16(min(delay, 65535)))
        data.append(contentsOf: [usesTransparency ? transparentIndex : 0x00, 0x00])
        // Image descriptor with a 256-entry local colour table.
        data.append(0x2C)
        data.append(le16(rx)); data.append(le16(ry))
        data.append(le16(rw)); data.append(le16(rh))
        data.append(0x87)
        data.append(palette)
        data.append(0x08)
        data.append(lzw(indices, similar: similarColors(palette, count: paletteCount, limit: lossy)))
        return data
    }

    /// Median cut over the non-empty 15-bit cells; colours are the true
    /// averages of their pixels, so large flat areas keep their exact colour.
    private static func buildPalette(counts: [Int32], sums: [Int64],
                                     maxColors: Int) -> (Data, [UInt8], Int) {
        struct Cell { let key: Int; let r: Int; let g: Int; let b: Int; let n: Int }
        var cells: [Cell] = []
        for key in 0..<32768 where counts[key] > 0 {
            let n = Int(counts[key])
            cells.append(Cell(key: key, r: Int(sums[key * 3]) / n, g: Int(sums[key * 3 + 1]) / n,
                              b: Int(sums[key * 3 + 2]) / n, n: n))
        }
        var boxes: [[Cell]] = [cells]
        if cells.count > maxColors {
            while boxes.count < maxColors {
                // Split the box with the widest weighted range.
                var best = -1, bestScore = -1, bestAxis = 0
                for (i, box) in boxes.enumerated() where box.count > 1 {
                    var lo = [255, 255, 255], hi = [0, 0, 0], weight = 0
                    for c in box {
                        lo[0] = min(lo[0], c.r); hi[0] = max(hi[0], c.r)
                        lo[1] = min(lo[1], c.g); hi[1] = max(hi[1], c.g)
                        lo[2] = min(lo[2], c.b); hi[2] = max(hi[2], c.b)
                        weight += c.n
                    }
                    let ranges = [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]]
                    let axis = ranges.firstIndex(of: ranges.max()!)!
                    let score = ranges[axis] * Int(Double(weight).squareRoot())
                    if score > bestScore { bestScore = score; best = i; bestAxis = axis }
                }
                guard best >= 0 else { break }
                let sorted = boxes[best].sorted {
                    bestAxis == 0 ? $0.r < $1.r : bestAxis == 1 ? $0.g < $1.g : $0.b < $1.b
                }
                let total = sorted.reduce(0) { $0 + $1.n }
                var acc = 0, cut = 1
                for (i, c) in sorted.enumerated() {
                    acc += c.n
                    if acc * 2 >= total { cut = max(1, min(sorted.count - 1, i + 1)); break }
                }
                boxes[best] = Array(sorted[..<cut])
                boxes.append(Array(sorted[cut...]))
            }
        } else {
            boxes = cells.isEmpty ? [] : cells.map { [$0] }
        }
        var palette = Data(count: 768)
        var lookup = [UInt8](repeating: 0, count: 32768)
        for (index, box) in boxes.enumerated() {
            var r = 0, g = 0, b = 0, n = 0
            for c in box { r += c.r * c.n; g += c.g * c.n; b += c.b * c.n; n += c.n }
            n = max(n, 1)
            palette[index * 3] = UInt8(r / n)
            palette[index * 3 + 1] = UInt8(g / n)
            palette[index * 3 + 2] = UInt8(b / n)
            for c in box { lookup[c.key] = UInt8(index) }
        }
        return (palette, lookup, boxes.count)
    }

    /// For each palette entry, the other entries within `limit` (closest
    /// first). The transparent index is never part of a list.
    private static func similarColors(_ palette: Data, count: Int, limit: Int) -> [[UInt8]] {
        guard limit > 0, count > 1 else { return [] }
        let threshold = limit * limit * 9
        var result = [[UInt8]](repeating: [], count: 256)
        for a in 0..<count {
            var near: [(Int, UInt8)] = []
            let ra = Int(palette[a * 3]), ga = Int(palette[a * 3 + 1]), ba = Int(palette[a * 3 + 2])
            for b in 0..<count where b != a {
                let dr = ra - Int(palette[b * 3]), dg = ga - Int(palette[b * 3 + 1])
                let db = ba - Int(palette[b * 3 + 2])
                // Weighted for perception: green counts most, blue least.
                let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                if distance <= threshold { near.append((distance, UInt8(b))) }
            }
            near.sort { $0.0 < $1.0 }
            result[a] = near.prefix(8).map(\.1)
        }
        return result
    }

    /// GIF LZW (8-bit minimum code size) with an open-addressing table. With
    /// `similar` lists, a run may continue through a nearly identical colour
    /// ("lossy LZW"), which keeps runs long despite video noise.
    private static func lzw(_ indices: [UInt8], similar: [[UInt8]] = []) -> Data {
        let clear = 256, end = 257
        let tableSize = 5003
        var hashKeys = [Int32](repeating: -1, count: tableSize)
        var hashCodes = [Int32](repeating: 0, count: tableSize)
        var nextCode = 258
        var codeSize = 9
        var out = [UInt8]()
        out.reserveCapacity(indices.count / 2)
        var bitBuffer = 0, bitCount = 0
        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }
        emit(clear)
        guard var prefix = indices.first.map(Int.init) else {
            emit(end)
            return blocks(out, bitBuffer: bitBuffer, bitCount: bitCount)
        }
        for n in 1..<max(1, indices.count) where n < indices.count {
            let c = Int(indices[n])
            let key = Int32(prefix << 8 | c)
            var slot = (c << 4 ^ prefix) % tableSize
            var found = -1
            while hashKeys[slot] != -1 {
                if hashKeys[slot] == key { found = Int(hashCodes[slot]); break }
                slot = slot == 0 ? tableSize - 1 : slot - 1
            }
            if found >= 0 {
                prefix = found
                continue
            }
            if !similar.isEmpty {
                for alternative in similar[c] {
                    let altKey = Int32(prefix << 8 | Int(alternative))
                    var altSlot = (Int(alternative) << 4 ^ prefix) % tableSize
                    while hashKeys[altSlot] != -1 {
                        if hashKeys[altSlot] == altKey { found = Int(hashCodes[altSlot]); break }
                        altSlot = altSlot == 0 ? tableSize - 1 : altSlot - 1
                    }
                    if found >= 0 { break }
                }
                if found >= 0 {
                    prefix = found
                    continue
                }
            }
            emit(prefix)
            if nextCode < 4096 {
                hashKeys[slot] = key
                hashCodes[slot] = Int32(nextCode)
                // The code is in use, so the width grows once it no longer fits.
                if nextCode == (1 << codeSize) { codeSize += 1 }
                nextCode += 1
            } else {
                emit(clear)
                for i in 0..<tableSize { hashKeys[i] = -1 }
                nextCode = 258
                codeSize = 9
            }
            prefix = c
        }
        emit(prefix)
        emit(end)
        return blocks(out, bitBuffer: bitBuffer, bitCount: bitCount)
    }

    private static func blocks(_ bytes: [UInt8], bitBuffer: Int, bitCount: Int) -> Data {
        var bytes = bytes
        if bitCount > 0 { bytes.append(UInt8(bitBuffer & 0xFF)) }
        var data = Data(capacity: bytes.count + bytes.count / 255 + 2)
        var offset = 0
        while offset < bytes.count {
            let length = min(255, bytes.count - offset)
            data.append(UInt8(length))
            data.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        }
        data.append(0)
        return data
    }

    private static func le16(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }
}

/// Reads a recording sequentially as BGRA frames at the output size and rate
/// (no seeking, which re-decodes from the last keyframe for every frame).
final class FrameSource {
    let width: Int
    let height: Int
    let fps: Int
    let videoEnd: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput

    init(video: URL, options: GIFOptions) throws {
        let asset = AVURLAsset(url: video)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw GIFConverter.Failure.invalidVideo
        }
        let videoEnd = CMTimeGetSeconds(track.timeRange.end)
        guard videoEnd.isFinite, videoEnd > 0 else { throw GIFConverter.Failure.invalidVideo }

        // Output size from the displayed (transformed) size.
        let transform = track.preferredTransform
        let natural = track.naturalSize.applying(transform)
        let shown = CGSize(width: abs(natural.width), height: abs(natural.height))
        guard shown.width >= 1, shown.height >= 1 else {
            throw GIFConverter.Failure.invalidVideo
        }
        let scale = min(1, Double(options.maxSide) / Double(max(shown.width, shown.height)))
        let width = max(2, Int((shown.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((shown.height * scale / 2).rounded()) * 2)
        let fps = max(1, options.fps)

        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        // Android encodes the screen as sRGB; keep it, the output is sRGB too.
        composition.colorPrimaries = options.displayP3 ? AVVideoColorPrimaries_P3_D65 :
                                                         AVVideoColorPrimaries_ITU_R_709_2
        if #available(macOS 15.0, *) {
            composition.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB
        } else {
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        }
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_601_4
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let instruction = AVMutableVideoCompositionInstruction()
        // Instructions must span the whole asset (audio can run a little longer).
        instruction.timeRange = CMTimeRange(start: .zero,
                                            duration: CMTimeMaximum(asset.duration, track.timeRange.end))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let sx = Double(width) / shown.width
        let sy = Double(height) / shown.height
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: sx, y: sy)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GIFConverter.Failure.invalidVideo }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? GIFConverter.Failure.invalidVideo }
        self.width = width
        self.height = height
        self.fps = fps
        self.videoEnd = videoEnd
        self.reader = reader
        self.output = output
    }

    /// The next frame (BGRA, tightly packed) and its time in seconds.
    func next() -> ([UInt8], Double)? {
        while true {
            var result: ([UInt8], Double)?
            var exhausted = false
            autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else {
                    exhausted = true
                    return
                }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                result = (Self.copyPixels(buffer, width: width, height: height), time)
            }
            if let result { return result }
            if exhausted { return nil }
        }
    }

    func finish() throws {
        if reader.status == .failed { throw reader.error ?? GIFConverter.Failure.invalidVideo }
    }

    static func copyPixels(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return pixels }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rows = min(height, CVPixelBufferGetHeight(buffer))
        let rowBytes = min(width, CVPixelBufferGetWidth(buffer)) * 4
        pixels.withUnsafeMutableBytes { target in
            for row in 0..<rows {
                memcpy(target.baseAddress! + row * width * 4, base + row * stride, rowBytes)
            }
        }
        return pixels
    }
}
