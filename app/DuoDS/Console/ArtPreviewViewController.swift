import UIKit

/// 그림 확인용 화면(실행 인자 `-DuoArtPreview open|nocard|carts`). 실제 흐름과 상관없이 그림만 늘어놓는다.
final class ArtPreviewViewController: UIViewController {
    private let mode: String
    private var emulator: Emulator?

    init(mode: String) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        switch mode {
        case "carts": showCarts()
        default: showOpen(game: mode == "open")
        }
    }

    private func showOpen(game: Bool) {
        let console = OpenConsoleView(frame: view.bounds)
        console.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        console.bent = true
        view.addSubview(console)
        console.leds.power = game ? .on : .off
        guard game, let rom = Library.shared.scan().first else { return }
        let emu = Emulator(rom: rom)
        do {
            try emu.start(settings: Settings.shared)
            emu.setPaused(false)
            console.renderer?.frames = emu.frames
            console.showsGame = true
            emulator = emu
        } catch {
            NSLog("preview: \(error)")
        }
    }

    private func showCarts() {
        view.backgroundColor = UIColor(hex: 0x2B2D33)
        let roms: [RomEntry?] = Library.shared.scan().filter { $0.url.lastPathComponent != "test.nds" } + [nil]
        let cols = 2
        let gap: CGFloat = 26
        let w = (view.bounds.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let h = w / CartridgeView.aspect
        for (i, rom) in roms.enumerated() {
            let card = CartridgeView(rom: rom)
            card.frame = CGRect(x: gap + CGFloat(i % cols) * (w + gap), y: 60 + CGFloat(i / cols) * (h + gap), width: w, height: h)
            view.addSubview(card)
        }
    }
}
