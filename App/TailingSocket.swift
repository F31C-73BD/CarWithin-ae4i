// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingSocket.swift
import Darwin
import Foundation

/// 非阻塞 TCP。每次操作持有 dup 描述符；关闭时 shutdown 唤醒读写，避免 fd 重用竞态。
final class TailingSocket: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = NSLock()
    private let operations = DispatchGroup()
    private var descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }

    var localPort: UInt16 {
        get throws {
            let fd = try duplicate()
            defer { release(fd) }
            var address = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            guard result == 0 else { throw TailingError.system(CWL("读取本机端口"), errno) }
            return UInt16(bigEndian: address.sin_port)
        }
    }

    static func create() throws -> TailingSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TailingError.system(CWL("创建 TCP"), errno) }
        let result = TailingSocket(fd)
        do {
            try configure(fd)
            return result
        } catch { result.close(); throw error }
    }

    static func listening(localIP: String, port: UInt16) throws -> TailingSocket {
        let socket = try create()
        do {
            try socket.listen(localIP: localIP, port: port)
            return socket
        } catch { socket.close(); throw error }
    }

    func listen(localIP: String, port: UInt16) throws {
        let fd = try duplicate()
        defer { release(fd) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        try Self.bind(fd, ip: localIP, port: port)
        guard Darwin.listen(fd, 4) == 0 else { throw TailingError.system(CWL("监听 TCP{1}", [String(describing: port)]), errno) }
    }

    func connect(localIP: String, remoteIP: String, port: UInt16, timeout: TimeInterval = 3) throws {
        let fd = try duplicate()
        defer { release(fd) }
        try Self.bind(fd, ip: localIP, port: 0)
        var address = try Self.address(remoteIP, port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw TailingError.system(CWL("连接 TCP{1}", [String(describing: port)]), errno) }
            try wait(fd, events: Int16(POLLOUT), deadline: Self.now + timeout, operation: CWL("连接 TCP{1}", [String(describing: port)]))
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
                throw TailingError.system(CWL("读取 TCP 状态"), errno)
            }
            guard error == 0 else { throw TailingError.system(CWL("连接 TCP{1}", [String(describing: port)]), error) }
        }
    }

    func accept(remoteIP: String) throws -> TailingSocket {
        let fd = try duplicate()
        defer { release(fd) }
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: nil, operation: CWL("等待仪表连接"))
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let accepted = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) }
            }
            if accepted < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw TailingError.system(CWL("接受 TCP"), errno)
            }
            let expected = try Self.address(remoteIP, 0)
            guard address.sin_family == sa_family_t(AF_INET),
                  address.sin_addr.s_addr == expected.sin_addr.s_addr else {
                Darwin.close(accepted)
                continue
            }
            let socket = TailingSocket(accepted)
            do { try Self.configure(accepted); return socket }
            catch { socket.close(); throw error }
        }
    }

    /// 对端端口（用于抓包标注，取不到就记 0）。
    var peerPort: UInt16 {
        guard let fd = try? duplicate() else { return 0 }
        defer { release(fd) }
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &size) }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: address.sin_port)
    }

    func readExactly(_ count: Int, timeout: TimeInterval? = 10, waitForFirstByte: Bool = false) throws -> Data {
        guard count >= 0, count <= 8 * 1_024 * 1_024 else {
            throw TailingError.protocolFailure(CWL("TCP 读取长度异常"))
        }
        if count == 0 { return Data() }
        let fd = try duplicate()
        defer { release(fd) }
        var deadline = waitForFirstByte ? nil : timeout.map { Self.now + $0 }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(fd, events: Int16(POLLIN), deadline: deadline, operation: CWL("接收仪表数据"))
            let received = data.withUnsafeMutableBytes { bytes in
                Darwin.recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received > 0 {
                if offset == 0 && waitForFirstByte {
                    deadline = timeout.map { Self.now + $0 }
                }
                offset += received
            } else if received == 0 { throw TailingError.closed }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw TailingError.system(CWL("接收 TCP"), errno)
            }
        }
        ProtocolTrace.shared.record(direction: "←", port: peerPort, data: data)
        return data
    }

    func write(_ data: Data, timeout: TimeInterval = 5) throws {
        writer.lock()
        defer { writer.unlock() }
        let fd = try duplicate()
        defer { release(fd) }
        let deadline = Self.now + timeout
        var offset = 0
        while offset < data.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, operation: CWL("发送仪表数据"))
            let sent = data.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent > 0 { offset += sent }
            else if sent == 0 { throw TailingError.closed }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw TailingError.system(CWL("发送 TCP"), errno)
            }
        }
        ProtocolTrace.shared.record(direction: "→", port: peerPort, data: data)
    }

    func close() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        // poll 最多50ms检查关闭状态；返回前释放所有dup，才能可靠地立即重绑端口。
        operations.wait()
    }

    private func duplicate() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw TailingError.closed }
        let copy = dup(descriptor)
        guard copy >= 0 else { throw TailingError.system(CWL("复制 TCP"), errno) }
        operations.enter()
        return copy
    }

    private func release(_ fd: Int32) {
        Darwin.close(fd)
        operations.leave()
    }

    private func wait(_ fd: Int32, events: Int16, deadline: TimeInterval?, operation: String) throws {
        while true {
            lock.lock()
            let closed = descriptor < 0
            lock.unlock()
            if closed { throw TailingError.closed }
            let remaining = deadline.map { $0 - Self.now } ?? 0.05
            guard remaining > 0 else { throw TailingError.timeout(operation) }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(max(1, min(50, remaining * 1_000))))
            if result > 0 {
                if item.revents & Int16(POLLNVAL) != 0 { throw TailingError.closed }
                return // recv/send/getsockopt reports EOF or the actual error, including POLLHUP.
            }
            if result < 0 && errno != EINTR { throw TailingError.system(operation, errno) }
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TailingError.system(CWL("设置 TCP 非阻塞"), errno)
        }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func bind(_ fd: Int32, ip: String, port: UInt16) throws {
        var address = try address(ip, port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw TailingError.system(CWL("绑定 {1}:{2}", [String(describing: ip), String(describing: port)]), errno) }
    }

    private static func address(_ ip: String, _ port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else {
            throw TailingError.protocolFailure(CWL("IPv4 地址无效"))
        }
        return address
    }
}


// MARK: - 通用协议抓包（内存环形缓冲，失败时自动落盘）

/// 记录所有 TCP/UDP 协议收发；默认只在内存里保留最近若干条，
/// 连接失败或“协商通过却没有首帧”时自动写到 Documents，供排查用。
final class ProtocolTrace: @unchecked Sendable {
    static let shared = ProtocolTrace()

    private let lock = NSLock()
    private var entries: [String] = []
    private var header = ""
    private let limit = 3000          // 条数上限
    private let maxBytesPerEntry = 512
    private let keepFiles = 3         // 最多保留 3 份失败抓包

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 每次启动/切换会话时写入环境头。
    func beginSession(_ text: String) {
        lock.lock()
        header = text
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func record(direction: String, port: UInt16, data: Data) {
        guard !data.isEmpty else { return }
        // 视频帧很大：只记长度，避免把控制消息挤出缓冲。
        if data.count > 4096 {
            let line = "\(formatter.string(from: Date())) \(direction) \(port) \(data.count)B  [视频帧，略]"
            lock.lock(); entries.append(line)
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
            lock.unlock()
            return
        }
        let head = data.prefix(maxBytesPerEntry).map { String(format: "%02x", $0) }.joined(separator: " ")
        let suffix = data.count > maxBytesPerEntry ? " …共 \(data.count) 字节" : ""
        let line = "\(formatter.string(from: Date())) \(direction) \(port) \(data.count)B  \(head)\(suffix)"
        lock.lock()
        entries.append(line)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
    }

    /// 手动保存当前抓包（成功会话也能存）。
    @discardableResult
    func saveNow(_ reason: String) -> URL? {
        saveOnFailure(reason)
    }

    /// 失败时落盘（最多保留 keepFiles 份）。
    @discardableResult
    func saveOnFailure(_ reason: String) -> URL? {
        lock.lock()
        let body = entries
        let head = header
        lock.unlock()
        guard !body.isEmpty else { return nil }

        let manager = FileManager.default
        guard let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        // 只留最近 keepFiles 份
        if let existing = try? manager.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) {
            let olds = existing
                .filter { $0.lastPathComponent.hasPrefix("protocol-fail-") && $0.pathExtension == "log" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in olds.dropLast(max(0, keepFiles - 1)) { try? manager.removeItem(at: url) }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = documents.appendingPathComponent("protocol-fail-\(stamp.string(from: Date())).log")
        let text = """
        CarWithin 协议抓包
        \(head)
        失败原因：\(reason)
        记录条数：\(body.count)

        \(body.joined(separator: "\n"))
        """
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
