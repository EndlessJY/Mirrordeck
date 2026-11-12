import Foundation

/// Reports iPhones and iPads being plugged in or removed, through the
/// system's usbmuxd (a local socket on this Mac; no network traffic).
final class AppleDeviceMonitor {
    var onChange: (() -> Void)?
    private var socketHandle: Int32 = -1
    private var stopped = false
    private let queue = DispatchQueue(label: "uk.agpt.lanadbmanager.usbmuxd")

    func start() {
        queue.async { [weak self] in self?.listen() }
    }

    func stop() {
        stopped = true
        // Wakes the listening thread, which closes the socket itself; closing
        // it here as well would close whatever reused that descriptor.
        let handle = socketHandle
        if handle >= 0 { shutdown(handle, SHUT_RDWR) }
    }

    private func listen() {
        while !stopped {
            if let handle = Self.connect() {
                socketHandle = handle
                if Self.send(["MessageType": "Listen", "ClientVersionString": "Mirrordeck",
                              "ProgName": "Mirrordeck"], to: handle) {
                    while !stopped, let message = Self.receive(from: handle) {
                        let type = message["MessageType"] as? String
                        if type == "Attached" || type == "Detached" {
                            DispatchQueue.main.async { [weak self] in self?.onChange?() }
                        }
                    }
                }
                close(handle)
                socketHandle = -1
            }
            // usbmuxd restarted or is not there yet: try again shortly.
            if !stopped { Thread.sleep(forTimeInterval: 5) }
        }
    }

    private static func connect() -> Int32? {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count - 1)))
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, size) }
        }
        if result != 0 {
            close(handle)
            return nil
        }
        return handle
    }

    /// usbmuxd frame: length, version 1, type 8 (plist), tag; then the plist.
    private static func send(_ message: [String: Any], to handle: Int32) -> Bool {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: message,
                                                             format: .xml, options: 0) else {
            return false
        }
        var header = [UInt32(16 + body.count), 1, 8, 1].map { $0.littleEndian }
        var frame = Data(bytes: &header, count: 16)
        frame.append(body)
        return frame.withUnsafeBytes { write(handle, $0.baseAddress, frame.count) } == frame.count
    }

    private static func receive(from handle: Int32) -> [String: Any]? {
        guard let header = read(handle, count: 16) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.load(as: UInt32.self))) }
        guard length >= 16, length < 1 << 20, let body = read(handle, count: length - 16) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }

    private static func read(_ handle: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let got = data.withUnsafeMutableBytes {
                Darwin.read(handle, $0.baseAddress! + offset, count - offset)
            }
            if got <= 0 { return nil }
            offset += got
        }
        return data
    }
}
