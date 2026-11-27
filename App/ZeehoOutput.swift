import CoreImage
import Foundation
import VideoToolbox

/// Keeps encoding and the instrument's TCP frame requests off the CarPlay receive queue.
final class ZeehoOutput {
    private let queue = DispatchQueue(label: "CarWithin.zeeho", qos: .userInitiated)
    private var session: Session?

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, profile: TailingDisplayProfile,
               frameRate: ZeehoFrameRate = .fps25,
               bitrateOverride: Int? = nil, encodeProfile: ZeehoEncodeProfile = .baseline,
               onStats: ((Double, Int) -> Void)? = nil,
               videoMode: ZeehoVideoMode = .transcode, sourceSize: InstrumentFrameSize? = nil,
               phone: TailingPhoneInfo, onState: @escaping (String) -> Void,
               onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        // 自动档按像素数放大码率（2048×968 是旧款 1024×480 的 4 倍，再留余量给文字边缘），
        // 手动档直接采用用户选的 Mbit/s；上限 24 Mbit/s 是为了压住帧率抖动。
        let automatic = min(24_000_000, Int((Double(frameRate.bitrate) * profile.bitrateScale).rounded()))
        let bitrate = bitrateOverride ?? automatic
        let level: CFString = encodeProfile == .main
            ? kVTProfileLevel_H264_Main_AutoLevel
            : kVTProfileLevel_H264_Baseline_AutoLevel
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           profile: profile, frameRate: frameRate, videoMode: videoMode,
                           sourceSize: sourceSize ?? profile.preferredSize, bitrate: bitrate,
                           prioritizeQuality: profile.prioritizesEncodingQuality,
                           profileLevel: level, encodeProfileName: encodeProfile.title,
                           onStats: onStats, phone: phone,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private let connection: TailingConnection
        private let frameRate: ZeehoFrameRate
        private let sourceSize: InstrumentFrameSize
        private let bitrate: Int
        private let prioritizeQuality: Bool
        private let profileLevel: CFString
        private let encodeProfileName: String
        private let onStats: ((Double, Int) -> Void)?
        private var usesRelay: Bool
        private var isRelaying: Bool { lock.withLock { usesRelay } }
        private let relayCondition = NSCondition()
        private var relayBuffer = ZeehoRelayBuffer()
        private var relayParameters = VideoParameterSets(codec: .h264)
        private var relayValidated = false
        private var relayError: Error?
        private var relayInputFrames = 0
        private var relayKeyframeRequestedAt = -Double.infinity
        private var relayPullTime = 0.0
        private var relayWriteTime = 0.0
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var fresh = false
        private let origin = ProcessInfo.processInfo.systemUptime
        private var lastFrame = -Double.infinity
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var nextHeartbeat = 0.0
        private var counter: UInt32 = 0
        private var loggedSource = false
        private var lastReply: Double?
        private var sentPicture = false
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, profile: TailingDisplayProfile,
             frameRate: ZeehoFrameRate,
             videoMode: ZeehoVideoMode, sourceSize: InstrumentFrameSize, bitrate: Int,
             prioritizeQuality: Bool, profileLevel: CFString, encodeProfileName: String,
             onStats: ((Double, Int) -> Void)?, phone: TailingPhoneInfo, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.frameRate = frameRate
            self.sourceSize = sourceSize
            self.bitrate = bitrate
            self.prioritizeQuality = prioritizeQuality
            self.profileLevel = profileLevel
            self.encodeProfileName = encodeProfileName
            self.onStats = onStats
            self.usesRelay = profile == .zeehoSEPlus && videoMode.effective(for: frameRate) == .relay
            self.connection = TailingConnection(localIP: localAddress, targetIP: targetAddress,
                profile: profile, phone: phone, log: onLog)
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start() {
            report(CWL("正在连接极核仪表…"))
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let size = try connection.start()
                    guard active else { return }
                    report("仪表已连接 · \(size)，等待 CarPlay 画面…")
                    if isRelaying, sourceSize != size {
                        lock.withLock { usesRelay = false }
                        onLog("直传尺寸 \(sourceSize) 与仪表 \(size) 不同，本次改用兼容转码")
                        requestKeyframe()
                    }
                    if isRelaying {
                        onLog("极核使用 H.264 原码流直传，不执行手机端解码、缩放或编码；仪表兼容性需实测")
                        try runRelay(size: size)
                    } else {
                        onLog("极核使用兼容转码，CarPlay 源画面 \(sourceSize)，仪表输出 \(size)")
                        var first = true
                        var nextFrame = ProcessInfo.processInfo.systemUptime
                        while active {
                            try connection.checkHealth()
                            let ready = queue.sync { latest != nil }
                            if !ready { Thread.sleep(forTimeInterval: 0.05); continue }
                            let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                            if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                            try connection.waitForH264Request()
                            nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(frameRate.rawValue)
                            guard active else { break }
                            let result = queue.sync { () -> H264EncodedFrame? in
                                guard active, let image = latest else { return nil }
                                return encode(image, size: size, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: first)
                            }
                            guard let result else {
                                // Preserve the pending pull request until an encodable frame is available.
                                var recovered: H264EncodedFrame?
                                for _ in 0..<20 where active && recovered == nil {
                                    Thread.sleep(forTimeInterval: 0.05)
                                    recovered = queue.sync {
                                        guard let image = latest else { return nil }
                                        return encode(image, size: size, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: true)
                                    }
                                }
                                guard let recovered else { throw TailingError.timeout(CWL("等待 H.264 编码画面")) }
                                try connection.sendH264(recovered.data)
                                first = false
                                reportFrameSent(size: size)
                                continue
                            }
                            try connection.sendH264(result.data)
                            first = false
                            reportFrameSent(size: size)
                        }
                    }
                } catch {
                    if active {
                        let raw = error.localizedDescription
                        onLog(CWL("极核连接失败（原始）：{1}", [String(describing: raw)]))
                        report(CWL("极核连接失败：{1}", [String(describing: Self.friendly(raw))]))
                    }
                }
                connection.close()
                queue.async { [self] in close() }
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
            relayCondition.lock(); relayCondition.broadcast(); relayCondition.unlock()
            connection.close()
        }

        func append(_ data: Data, keyframe: Bool) {
            if isRelaying {
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                appendRelay(data)
                return
            }
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func appendRelay(_ data: Data) {
            var needsKeyframe = false
            relayCondition.lock()
            defer {
                relayCondition.signal(); relayCondition.unlock()
                if needsKeyframe { requestRelayKeyframe() }
            }
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if relayParameters.absorb(unit) {
                            relayBuffer.reset(); relayValidated = false
                        }
                    } else { picture.append(unit) }
                }
                guard relayParameters.isComplete else { needsKeyframe = true; return }
                if !relayValidated {
                    let units = relayParameters.ordered.map { $0 as NSData }
                    let pointers = units.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
                    var description: CMVideoFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count, parameterSetPointers: pointers,
                        parameterSetSizes: units.map(\.length), nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                    guard status == noErr, let description else { throw ConfigurationError("H.264 直传参数无效（\(status)），请改用兼容转码") }
                    let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(description,
                        usePixelAspectRatio: false, useCleanAperture: true)
                    let actual = InstrumentFrameSize(width: Int(dimensions.width.rounded()), height: Int(dimensions.height.rounded()))
                    guard actual == sourceSize else { throw ConfigurationError("H.264 源尺寸 \(actual) 与直传尺寸 \(sourceSize) 不同，请改用兼容转码") }
                    relayValidated = true
                    onLog("极核直传源规格：\(try relayParameters.codecString()) · \(actual)")
                }
                guard picture.contains(where: { [1, 5].contains(Int(VideoCodec.h264.nalType($0) ?? 0)) }) else { return }
                relayInputFrames += 1
                let keyframe = picture.contains { VideoCodec.h264.isRandomAccess($0) }
                var frame = Data()
                for unit in (keyframe ? relayParameters.ordered : []) + picture {
                    frame.append(contentsOf: [0, 0, 0, 1]); frame.append(unit)
                }
                needsKeyframe = relayBuffer.append(frame, keyframe: keyframe)
            } catch {
                relayError = error
            }
        }

        private func requestRelayKeyframe() {
            let now = ProcessInfo.processInfo.systemUptime
            relayCondition.lock()
            let needed = now - relayKeyframeRequestedAt >= 1
            if needed { relayKeyframeRequestedAt = now }
            relayCondition.unlock()
            if needed, active { requestKeyframe() }
        }

        private func nextRelayFrame() throws -> Data? {
            relayCondition.lock(); defer { relayCondition.unlock() }
            if let error = relayError { throw error }
            if let frame = relayBuffer.pop() { return frame }
            _ = relayCondition.wait(until: Date(timeIntervalSinceNow: 0.5))
            if let error = relayError { throw error }
            return relayBuffer.pop()
        }

        private func runRelay(size: InstrumentFrameSize) throws {
            var lastPicture = ProcessInfo.processInfo.systemUptime
            while active {
                try connection.checkHealth()
                guard let frame = try nextRelayFrame() else {
                    guard active else { break }
                    requestRelayKeyframe()
                    if ProcessInfo.processInfo.systemUptime - lastPicture >= 10 {
                        throw ConfigurationError("H.264 直传连续 10 秒未收到完整源画面，请查看锁屏前后日志或改用兼容转码")
                    }
                    continue
                }
                guard active else { break }
                let pullStarted = ProcessInfo.processInfo.systemUptime
                try connection.waitForH264Request()
                let writeStarted = ProcessInfo.processInfo.systemUptime
                try connection.sendH264(frame)
                let now = ProcessInfo.processInfo.systemUptime
                relayPullTime += writeStarted - pullStarted
                relayWriteTime += now - writeStarted
                lastPicture = now
                reportFrameSent(size: size)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    // Throttle rebuilds while VideoToolbox is unavailable during a lock transition.
                    guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                    guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                        requestKeyframe()
                        return
                    }
                    decoder?.invalidate()
                    decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                        output: { [weak self] image in
                            guard let self else { return }
                            self.lock.withLock { self.decoded = image }
                        }, failure: { [weak self] error in
                            guard let self else { return }
                            self.lock.withLock { self.decodeError = error }
                        })
                    waitingForIDR = false
                }
                guard let decoder, !picture.isEmpty else { return }
                try decoder.decode(AnnexB.lengthPrefixed(picture),
                    presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                decoder.waitForFrames()
                let (image, error) = lock.withLock {
                    defer { decoded = nil; decodeError = nil }
                    return (decoded, decodeError)
                }
                if let error { throw error }
                if let image { latest = image; fresh = true }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure(CWL("解码"), error)
                requestKeyframe()
            }
        }

        private func encode(_ image: CVPixelBuffer, size: InstrumentFrameSize, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            do {
                if !loggedSource {
                    loggedSource = true
                    let source = InstrumentFrameSize(width: CVPixelBufferGetWidth(image),
                                                     height: CVPixelBufferGetHeight(image))
                    onLog("极核源画面 \(source) → 输出 \(size)\(source == size ? "（一比一）" : "（\(source) 已缩放）")")
                }
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: size.width, height: size.height,
                                              fps: frameRate.rawValue, bitrate: bitrate,
                                              prioritizeQuality: prioritizeQuality,
                                              profileLevel: profileLevel) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                try encoder.encode(try fittedImage(image, to: size), presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                   forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                let frame = try result?.get()
                if frame?.isKeyframe == true { lastKeyframe = now }
                return frame
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lastKeyframe = -.infinity
                lock.withLock { encoded = nil }
                logCodecFailure(CWL("编码"), error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer, to size: InstrumentFrameSize) throws -> CVPixelBuffer {
            let width = size.width, height = size.height
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw ConfigurationError(CWL("无法分配极核缩放画面（{1}）", [String(describing: status)])) }
            let source = CIImage(cvPixelBuffer: image)
            let destination = size.fittedRect(for: source.extent.size)
            let scale = destination.width / source.extent.width
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: destination.minX - scaled.extent.minX,
                y: destination.minY - scaled.extent.minY))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func reportFrameSent(size: InstrumentFrameSize) {
            let now = ProcessInfo.processInfo.systemUptime
            if !sentPicture {
                sentPicture = true
                if isRelaying {
                    onLog("极核首帧已发送 · \(size) · H.264 直传 · 源目标 \(frameRate.rawValue) FPS · 码率由 CarPlay 决定")
                } else {
                    let actual = String(format: "%.1f", Double(bitrate) / 1_000_000)
                    onLog("极核首帧已发送 · \(size) · 兼容转码 · 目标 \(frameRate.rawValue) FPS · 码率 \(actual) Mbit/s")
                }
            }
            if let started = lastReply {
                counter &+= 1
                let duration = now - started
                if duration >= 5 {
                    let rate = Double(counter) / duration
                    onLog(String(format: "极核实际发送 %.1f FPS，目标 %d FPS（%.1f 秒 / %u 帧）",
                                 rate, frameRate.rawValue, duration, counter))
                    onStats?(rate, bitrate)
                    if isRelaying {
                        relayCondition.lock()
                        let inputs = relayInputFrames
                        let discarded = relayBuffer.discardedGroups
                        relayInputFrames = 0
                        relayCondition.unlock()
                        onLog(String(format: "极核直传输入 %.1f FPS，拉帧等待 %.1f ms/帧，写入 %.1f ms/帧，累计丢弃积压帧组 %d",
                            Double(inputs) / duration, relayPullTime * 1000 / Double(counter), relayWriteTime * 1000 / Double(counter), discarded))
                        relayPullTime = 0; relayWriteTime = 0
                    }
                    counter = 0
                    lastReply = now
                }
            } else {
                lastReply = now
                relayCondition.lock(); relayInputFrames = 0; relayCondition.unlock()
                relayPullTime = 0; relayWriteTime = 0
            }
            report("正在投屏 · \(size) · H.264 · 目标 \(frameRate.rawValue) FPS")
        }

        /// 把协议层错误翻译成用户看得懂的原因（原始错误仍写日志）。
        static func friendly(_ raw: String) -> String {
            if raw.contains("自动查找未发现仪表") || raw.contains("未发现仪表") {
                return "手机没连上仪表 Wi-Fi，或仪表还没打开投屏（MotoPlay）。可关掉「自动查找仪表 IP」后手动填仪表地址再试。"
            }
            if raw.contains("配置不符") || raw.contains("媒体尺寸") {
                return "仪表分辨率与当前车型不匹配，请在「输出设置 → 车型选择」里换成对应车型。"
            }
            if raw.contains("会话已关闭") {
                return "仪表主动断开了投屏（可能退出了投屏页），请在仪表上重新打开投屏。"
            }
            if raw.contains("连接被重置") || raw.contains("Connection reset") {
                return "连接被仪表重置，通常是仪表退出投屏或 Wi-Fi 抖动，可重新启动一次。"
            }
            if raw.contains("超时") || raw.contains("timeout") {
                return "仪表没有响应：请确认手机连的是仪表 Wi-Fi，且仪表已打开投屏。"
            }
            if raw.contains("MFi") || raw.contains("身份") {
                return "MFi 身份异常，请在「关于」页重新导入身份文件。"
            }
            return raw
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog(CWL("极核{1}恢复：{2}", [String(describing: stage), String(describing: error.localizedDescription)])) }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        private func fail(_ error: Error) {
            let message = CWL("极核输出失败：{1}", [String(describing: error.localizedDescription)])
            onLog(message)
            report(message)
            close()
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            connection.close()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
            relayCondition.lock(); relayBuffer.reset(); relayCondition.broadcast(); relayCondition.unlock()
        }
    }
}
