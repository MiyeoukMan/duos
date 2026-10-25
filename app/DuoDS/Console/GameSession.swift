import Foundation

/// 꽂힌 카트리지 한 장의 게임. 꽂는 순간 뒤에서 ROM을 읽어 부팅해 두고(멈춘 채), 펼치면 바로 돈다.
/// 접으면(앱이 뒤로 가도) 그 자리를 `<이름>.suspend.mst`에 저장하고 멈춘다. 다음에 그 카드를 꽂으면 거기서 이어진다.
final class GameSession {
    let rom: RomEntry
    let emulator: Emulator
    private(set) var ready = false
    private(set) var failure: String?
    /// 이번에 펼친 뒤로 실제로 돌았는가(안 돌았으면 접어도 다시 저장하지 않는다)
    private var playedSinceSuspend = false
    /// 한 번이라도 돌았는가(접었을 때 전원 불빛을 "절전"으로 깜빡일지)
    private(set) var hasRun = false
    private var waiting: [() -> Void] = []

    var suspendURL: URL { Library.shared.statesDir.appendingPathComponent(rom.baseName + ".suspend.mst") }
    var hasSuspend: Bool { FileManager.default.fileExists(atPath: suspendURL.path) }

    init(rom: RomEntry) {
        self.rom = rom
        emulator = Emulator(rom: rom)
    }

    /// 뒤에서 ROM을 읽고 부팅한다. 이어 할 자리가 있으면 그것까지 불러 둔다.
    func boot(_ done: ((String?) -> Void)? = nil) {
        let emu = emulator
        DispatchQueue.global(qos: .userInitiated).async {
            var message: String?
            do { try emu.load(settings: Settings.shared) } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                if let message {
                    self.failure = message
                } else {
                    emu.begin()
                    if self.hasSuspend { emu.loadState(from: self.suspendURL) { _ in } }
                    self.ready = true
                    self.waiting.forEach { $0() }
                }
                self.waiting.removeAll()
                done?(message)
            }
        }
    }

    func whenReady(_ f: @escaping () -> Void) {
        if ready { f() } else if failure == nil { waiting.append(f) }
    }

    func play() {
        whenReady { [weak self] in
            self?.playedSinceSuspend = true
            self?.hasRun = true
            self?.emulator.setPaused(false)
        }
    }

    func pause() { emulator.setPaused(true) }

    /// 접을 때: 멈추고 그 자리를 저장. 이번에 돌지 않았으면 저장할 것이 없다.
    func suspend(_ done: @escaping (Bool) -> Void) {
        guard ready, playedSinceSuspend else {
            if ready { emulator.setPaused(true) }
            done(false)
            return
        }
        playedSinceSuspend = false
        emulator.suspend(to: suspendURL, done: done)
    }

    /// 처음부터: 이어 할 자리를 지우고 다시 부팅
    func restart() {
        try? FileManager.default.removeItem(at: suspendURL)
        emulator.reset()
    }

    func stop() {
        waiting.removeAll()
        emulator.stop()
    }
}
