import Foundation
import Darwin

let socketPath = ProcessInfo.processInfo.environment["SWIFTHOOK_SOCKET"] ?? NSTemporaryDirectory().appending("swiftlauncher-\(NSUserName()).sock")
let text = CommandLine.arguments.dropFirst().joined(separator: " ")
guard !text.isEmpty else { fputs("Usage: swiftlauncher-cli <text>\n", stderr); exit(64) }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fputs("swiftlauncher-cli: cannot create socket\n", stderr); exit(1) }
defer { close(fd) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let socketPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
_ = socketPath.withCString { source in
    withUnsafeMutablePointer(to: &address.sun_path) { destination in
        destination.withMemoryRebound(to: CChar.self, capacity: socketPathCapacity) { strncpy($0, source, socketPathCapacity - 1) }
    }
}
let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
guard connected == 0 else { fputs("swiftlauncher-cli: Swiftlauncher is not running\n", stderr); exit(2) }
let body = Array(text.utf8)
let count = UInt32(body.count)
let packet = [
    UInt8((count >> 24) & 0xff),
    UInt8((count >> 16) & 0xff),
    UInt8((count >> 8) & 0xff),
    UInt8(count & 0xff)
] + body
let written = packet.withUnsafeBytes { write(fd, $0.baseAddress!, packet.count) }
guard written == packet.count else { fputs("swiftlauncher-cli: failed to send text\n", stderr); exit(3) }
