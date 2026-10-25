import AVFoundation
import Foundation
import Metal
import QuartzCore

/// melonDS 코어 하나를 따로 도는 스레드에서 59.83Hz로 돌린다.
/// - 화면: 프레임마다 두 장을 `FrameStore`에 넘긴다(그리는 쪽은 가장 새 것을 가져간다). 3D 해상도가 2배 이상이면
///   3D가 있던 화면의 고해상도 그림(Metal 텍스처)도 같이.
/// - 소리: 48kHz를 `AudioRing`에 넣고 AVAudioEngine이 꺼내 간다. 링이 너무 차거나 비면 프레임 간격을 아주 조금 늘이고 줄여 맞춘다.
/// - 입력: `setKeys` · `setTouch`는 아무 스레드에서나(코어가 원자 변수로 받는다).
final class Emulator {
    static let frameRate = 59.8261

    let rom: RomEntry
    let frames = FrameStore()
    private(set) var core: OpaquePointer?

    private let ring: OpaquePointer
    private var engine: AVAudioEngine?
    private var thread: Thread?
    private let cond = NSCondition()
    private var paused = true
    private var quit = false
    private var pending: [(OpaquePointer) -> Void] = []
    private var volume: Float = 1

    /// 빨리 감기(소리는 버린다)
    var fastForward = false
    /// 최근 1초의 초당 프레임(에뮬레이션)
    private(set) var measuredFps: Double = 0

    init(rom: RomEntry) {
        self.rom = rom
        ring = audio_ring_create(8192)!
    }

    deinit {
        stop()
        audio_ring_destroy(ring)
    }

    /// ROM을 넣고 켠다(멈춘 채). 실패하면 사람이 읽을 수 있는 이유를 던진다.
    func start(settings: Settings) throws {
        try load(settings: settings)
        begin()
    }

    /// 무거운 부분(ROM 읽기 · 부팅) — 아무 스레드에서나. 끝나면 주 스레드에서 `begin()`.
    func load(settings: Settings) throws {
        ds_set_local_dir(Library.shared.supportDir.path)
        let c = ds_create()!
        var err = [CChar](repeating: 0, count: 256)
        settings.nickname.withCString { name in
            var user = DSFirmwareUser(nickname: name, language: Int32(settings.language), favorite_color: Int32(settings.favoriteColor),
                                      birthday_month: Int32(settings.birthdayMonth), birthday_day: Int32(settings.birthdayDay))
            ds_set_firmware_user(c, &user)
        }
        settings.macAddress.withUnsafeBufferPointer { ds_set_mac(c, $0.baseAddress) }
        ds_set_3d_scale(c, Int32(settings.scale3D.rawValue))
        let r = ds_load_rom(c, rom.url.path, rom.saveURL.path, &err, Int32(err.count))
        if r != 0 {
            ds_destroy(c)
            throw EmulatorError.load(String(cString: err))
        }
        core = c
        volume = settings.volume
        ds_net_log_note("게임 켬: \(rom.title) (\(rom.gameCode))")
    }

    /// 소리 엔진과 에뮬레이션 스레드를 멈춘 채로 띄운다(주 스레드). `setPaused(false)`로 돌기 시작한다.
    func begin() {
        guard core != nil, thread == nil else { return }
        startAudio()
        let t = Thread { [weak self] in self?.run() }
        t.name = "DuoDS emulation"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        cond.lock()
        quit = true
        paused = false
        cond.broadcast()
        cond.unlock()
        while let t = thread, !t.isFinished { usleep(1000) }
        thread = nil
        engine?.stop()
        engine = nil
        if let c = core {
            ds_flush_save(c)
            ds_destroy(c)
            core = nil
        }
    }

    var isPaused: Bool {
        cond.lock(); defer { cond.unlock() }
        return paused
    }

    func setPaused(_ p: Bool) {
        cond.lock()
        paused = p
        cond.broadcast()
        cond.unlock()
        if p {
            engine?.pause()
            enqueue { ds_flush_save($0) }
        } else {
            try? engine?.start()
        }
    }

    func setVolume(_ v: Float) { volume = v }

    // ── 입력 ─────────────────────────────────

    func setKeys(_ keys: UInt32) { if let c = core { ds_set_keys(c, keys) } }
    func setTouch(_ point: CGPoint?) {
        guard let c = core else { return }
        if let p = point { ds_set_touch(c, 1, Int32(p.x), Int32(p.y)) } else { ds_set_touch(c, 0, 0, 0) }
    }
    func setLidClosed(_ closed: Bool) { if let c = core { ds_set_lid_closed(c, closed ? 1 : 0) } }
    func setMicBlow(_ on: Bool) { if let c = core { ds_set_mic_blow(c, on ? 1 : 0) } }
    /// 3D 내부 해상도(1~4) — 다음 프레임부터
    func setScale3D(_ k: Int) { if let c = core { ds_set_3d_scale(c, Int32(k)) } }

    // ── 에뮬레이션 스레드에서 할 일(상태 저장 등) ─────────

    /// 다음 프레임 앞에서 코어를 건드린다. 멈춰 있어도 돈다. 끝나면 완료 처리기를 주 스레드에서 부른다.
    func enqueue(_ work: @escaping (OpaquePointer) -> Void) {
        cond.lock()
        pending.append(work)
        cond.broadcast()
        cond.unlock()
    }

    /// 멈추고 그 자리를 상태 파일로(세이브도 같이 쓴다). 접을 때 · 앱이 뒤로 갈 때.
    func suspend(to url: URL, done: @escaping (Bool) -> Void) {
        setPaused(true)
        enqueue { c in
            let ok = ds_save_state(c, url.path) == 0
            ds_flush_save(c)
            DispatchQueue.main.async { done(ok) }
        }
    }

    func saveState(to url: URL, done: @escaping (Bool) -> Void) {
        enqueue { c in
            let ok = ds_save_state(c, url.path) == 0
            DispatchQueue.main.async { done(ok) }
        }
    }

    func loadState(from url: URL, done: @escaping (Bool) -> Void) {
        enqueue { [ring] c in
            let ok = ds_load_state(c, url.path) == 0
            audio_ring_clear(ring)
            DispatchQueue.main.async { done(ok) }
        }
    }

    func reset() {
        enqueue { [ring] c in
            ds_reset(c)
            audio_ring_clear(ring)
        }
    }

    // ── 돌리기 ───────────────────────────────

    private func run() {
        guard let c = core else { return }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func toTicks(_ s: Double) -> UInt64 { UInt64(s * 1e9 * Double(timebase.denom) / Double(timebase.numer)) }
        let period = 1.0 / Emulator.frameRate
        var next = mach_absolute_time()
        var audioBuf = [Int16](repeating: 0, count: 4096 * 2)
        var fpsCount = 0
        var fpsStart = CACurrentMediaTime()
        // 링에 이만큼(약 50ms) 쌓여 있게 맞춘다
        let target = Int32(Double(DS_AUDIO_RATE) * 0.05)

        while true {
            cond.lock()
            while (paused && pending.isEmpty) && !quit { cond.wait() }
            let work = pending
            pending.removeAll()
            let isPaused = paused
            let stopping = quit
            cond.unlock()

            for w in work { w(c) }   // 멈추기 직전에 넣은 일(자동 저장 등)도 끝내고 나간다
            if stopping { break }
            if isPaused { next = mach_absolute_time(); continue }

            ds_run_frame(c)
            if let top = ds_screen(c, 0), let bottom = ds_screen(c, 1) {
                frames.publish(top: top, bottom: bottom, hires: [Self.hiresTexture(c, 0), Self.hiresTexture(c, 1)])
            }
            let ff = fastForward
            audioBuf.withUnsafeMutableBufferPointer { buf in
                while true {
                    let n = ds_read_audio(c, buf.baseAddress, 4096)
                    if n <= 0 { break }
                    if !ff { audio_ring_write(ring, buf.baseAddress, n) }
                }
            }

            fpsCount += 1
            let now = CACurrentMediaTime()
            if now - fpsStart >= 1 {
                measuredFps = Double(fpsCount) / (now - fpsStart)
                fpsCount = 0
                fpsStart = now
            }

            if ff {
                next = mach_absolute_time()
                continue
            }
            // 소리가 모자라면 조금 빨리, 넘치면 조금 늦게(±0.5%) — 귀에는 안 들리고 끊김 · 늘어짐을 막는다
            let fill = audio_ring_available(ring)
            var p = period
            if fill < target / 2 { p *= 0.995 } else if fill > target * 2 { p *= 1.005 }
            next &+= toTicks(p)
            let t = mach_absolute_time()
            if next > t {
                mach_wait_until(next)
            } else if t - next > toTicks(0.1) {
                next = t   // 크게 밀렸으면(무거운 장면 · 잠깐 멈춤) 따라잡으려 하지 않는다
            }
        }
    }

    /// 코어가 이 프레임에 만든 고해상도 화면(3D가 있던 화면만) — 코어가 3장을 돌려 쓰므로 그리는 쪽이 바로 복사한다
    private static func hiresTexture(_ c: OpaquePointer, _ screen: Int32) -> MTLTexture? {
        guard let p = ds_screen_texture(c, screen, nil, nil) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? MTLTexture
    }

    // ── 소리 ─────────────────────────────────

    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredSampleRate(Double(DS_AUDIO_RATE))
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setActive(true)

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(DS_AUDIO_RATE), channels: 2)!
        let ring = self.ring
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            let vol = self?.volume ?? 0
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            audio_ring_read_float(ring, l, r, Int32(frameCount), vol)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        self.engine = engine   // 켜는 것은 setPaused(false)에서
    }
}

enum EmulatorError: LocalizedError {
    case load(String)
    var errorDescription: String? {
        switch self {
        case .load(let s): return s
        }
    }
}

/// 에뮬레이션 스레드가 쓰고 그리는 쪽이 읽는 화면 두 장. 잠금 안에서 복사한다(한 번에 약 0.2MB).
/// 고해상도 그림(3D 해상도 2배 이상, 3D가 있던 화면)은 텍스처 참조만 넘긴다 — 받는 쪽이 그 그리기 안에서 복사한다.
final class FrameStore {
    static let pixels = DS_SCREEN_WIDTH * DS_SCREEN_HEIGHT

    private let lock = NSLock()
    private var top = [UInt32](repeating: 0xFF000000, count: FrameStore.pixels)
    private var bottom = [UInt32](repeating: 0xFF000000, count: FrameStore.pixels)
    private var hires: [MTLTexture?] = [nil, nil]
    private(set) var serial: UInt64 = 0

    func publish(top t: UnsafePointer<UInt32>, bottom b: UnsafePointer<UInt32>, hires h: [MTLTexture?] = [nil, nil]) {
        lock.lock()
        top.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: t, count: FrameStore.pixels) }
        bottom.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: b, count: FrameStore.pixels) }
        hires = h
        serial &+= 1
        lock.unlock()
    }

    /// 마지막으로 본 번호보다 새 것이 있으면 두 장(+ 고해상도 그림)을 넘겨준다.
    func read(ifNewerThan seen: UInt64, _ body: (UnsafePointer<UInt32>, UnsafePointer<UInt32>, [MTLTexture?]) -> Void) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard serial != seen else { return seen }
        top.withUnsafeBufferPointer { t in
            bottom.withUnsafeBufferPointer { b in body(t.baseAddress!, b.baseAddress!, hires) }
        }
        return serial
    }
}
