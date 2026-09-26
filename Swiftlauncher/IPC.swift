import Foundation
import Darwin

enum SwiftlauncherIPC {
    static let socketPath = ProcessInfo.processInfo.environment["SWIFTHOOK_SOCKET"] ?? NSTemporaryDirectory().appending("swiftlauncher-\(NSUserName()).sock")
    static let maxMessageBytes = 1_048_576
}

final class SwiftlauncherIPCServer {
    private var listener: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.swiftlauncher.ipc")
    private let onText: (String) -> Void
    init(onText: @escaping (String) -> Void) { self.onText = onText }

    func start() {
        let path = SwiftlauncherIPC.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("IPC socket creation failed"); return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let socketPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: socketPathCapacity) { strncpy($0, source, socketPathCapacity - 1) }
            }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); print("IPC socket bind/listen failed"); return }
        chmod(path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { close(fd); unlink(path) }
        listener = source
        source.resume()
        print("Swiftlauncher IPC listening at \(path)")
    }

    private func accept(_ fd: Int32) {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            defer { close(client) }
            var header = [UInt8](repeating: 0, count: 4)
            guard Self.readFully(client, into: &header) else { return }
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= SwiftlauncherIPC.maxMessageBytes else { return }
            var body = [UInt8](repeating: 0, count: Int(length))
            guard Self.readFully(client, into: &body), let text = String(bytes: body, encoding: .utf8), !text.isEmpty else { return }
            DispatchQueue.main.async { self?.onText(text) }
        }
    }

    private static func readFully(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
        var offset = 0
        while offset < buffer.count {
            let remaining = buffer.count - offset
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), remaining) }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
}
