import UIKit
import UniformTypeIdentifiers

/// 앱의 단 하나의 화면: 듀오를 접으면 DS 뒷면(가로), 펼치면 펼친 DS(세로).
///
/// - 접은 상태: 슬롯을 누르면 카트리지 고르기 → 고르면 꽂는 애니메이션, 그와 함께 뒤에서 부팅해 둔다. 배터리 덮개를 누르면 설정.
///   접는 순간 = DS 뚜껑 닫기(GameSession.close — 게임에 알리고 잠깐 뒤 저장), 펴는 순간 = 뚜껑 열기(GameSession.play).
/// - 펼치는 순간: 꽂힌 카드가 있으면 바로 돈다(없으면 "카드 없음" 화면). SETTINGS 버튼 = 설정(게임 메뉴 포함).
/// - 접는 순간: 그 자리를 자동 저장하고 멈춘다(전원 불빛이 천천히 깜빡임). 다시 펼치면 이어서.
/// 접힘은 UIHingeInteraction. 시뮬레이터에선 실행 인자 `-DuoHinge closed|partial`과 두 손가락 톡(접기 ↔ 펴기).
final class ConsoleViewController: UIViewController {
    private let hinge = HingeMonitor()
    private let controller = ControllerInput()
    private let openView = OpenConsoleView()
    private let closedView = ClosedConsoleView()
    private let fpsLabel = UILabel()
    /// 화면 전체를 담는 판. 보통은 똑바로(시스템이 방향을 맞춰 준다). 시스템이 방향 지정을 끝내 안 받아 주면(0.7초) 예비로 이 판을 90° 돌린다
    private let stage = UIView()
    private var stageRotated = false
    private var mismatchSince: CFTimeInterval?
    private var picker: CartridgePickerView?
    private var session: GameSession?
    private var folded: Bool?
    private var swapped = false
    private var touchKeys: UInt32 = 0
    private var fpsTimer: Timer?
    /// 설정 카드(게임 화면 위에 얹는다)
    private var settingsNav: UINavigationController?
    private let settingsScrim = UIControl()
    private var settingsOpen: Bool { settingsNav != nil }

    /// 화면 방향: 펼침 = 세로, 접음 = 가로로 돌려 달라고 요청하고(requestGeometryUpdate) 그 자리에서 잠근다(prefersInterfaceOrientationLocked, iOS 26)
    /// — 기기를 돌려도 안 돈다. 시스템의 회전 애니메이션은 앱이 끌 수 없어서(setAnimationsEnabled도 소용없음), 도는 동안 판을 감췄다가 다 돈 뒤 나타나게 한다.
    /// · 듀오(iOS 27)는 앱이 창 모드라 요청을 거절하는데(UISceneErrorDomain 101), Info.plist의 UIRequiresFullScreen이 있으면 받아 준다
    ///   (2026-10-25 시뮬레이터로 확인 — 게임 모드 키와는 상관없음).
    /// · 지원 방향(supportedInterfaceOrientations · Info.plist)을 하나로 좁히면 시스템이 돌리지 않고 가로 화면 가운데 작은 세로 창으로 띄운다 → 좁히지 않는다.
    override var prefersInterfaceOrientationLocked: Bool { orientationLocked }
    private var orientationLocked = false {
        didSet { if orientationLocked != oldValue { setNeedsUpdateOfPrefersInterfaceOrientationLocked() } }
    }
    private var lockSettling = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(stage)
        stage.addSubview(openView)
        stage.addSubview(closedView)

        openView.controls.onKeys = { [weak self] k in self?.touchKeys = k; self?.pushKeys() }
        openView.controls.onTouch = { [weak self] p in self?.session?.emulator.setTouch(p) }
        openView.controls.onMic = { [weak self] on in self?.session?.emulator.setMicBlow(on) }
        openView.controls.onSettings = { [weak self] in self?.openSettings() }
        openView.noCard.pickButton.addAction(UIAction { [weak self] _ in self?.showPicker() }, for: .touchUpInside)

        closedView.onSlot = { [weak self] in self?.slotTapped() }
        closedView.onCover = { [weak self] in
            guard let self else { return }
            self.closedView.openCover(true) { self.openSettings() }
        }

        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        fpsLabel.textAlignment = .center
        stage.addSubview(fpsLabel)

        controller.onKeys = { [weak self] _ in self?.pushKeys() }

        // 앱을 다시 켜면 꽂아 둔 카드가 그대로
        if let name = Settings.shared.insertedCartridge, let rom = Library.shared.scan().first(where: { $0.url.lastPathComponent == name }) {
            closedView.showInserted(rom)
            startSession(rom)
        } else {
            Settings.shared.insertedCartridge = nil
        }

        hinge.onChange = { [weak self] in self?.hingeChanged() }
        hinge.attach(to: view)

        #if targetEnvironment(simulator)
        let toggle = UITapGestureRecognizer(target: self, action: #selector(simulateFold))
        toggle.numberOfTouchesRequired = 2
        toggle.numberOfTapsRequired = 1
        view.addGestureRecognizer(toggle)
        #endif

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(willResign), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        nc.addObserver(self, selector: #selector(wirelessChanged), name: Wireless.didChange, object: nil)
        nc.addObserver(self, selector: #selector(wirelessChanged), name: Internet.didChange, object: nil)

        settingsChanged()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if folded == nil { hingeChanged() }
        layoutStage()
    }

    /// 접음 = 가로, 펼침 = 세로. 시스템 방향이 그와 다르면 판을 90° 돌려 기기(하드웨어) 기준으로 맞춘다
    private func layoutStage() {
        let b = view.bounds
        guard b.width > 0 else { return }
        let systemPortrait = b.height >= b.width
        let wantPortrait = folded != true
        // 방향이 안 맞으면 먼저 시스템이 돌려 주길 기다리고(접고 펼 때 잠깐), 0.7초가 지나도 그대로면 판을 돌린다
        var rotated = false
        if systemPortrait != wantPortrait && folded != nil {
            let now = CACurrentMediaTime()
            if let since = mismatchSince {
                rotated = now - since >= 0.65
            } else {
                mismatchSince = now
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.layoutStage() }
            }
        } else {
            mismatchSince = nil
        }
        let current = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        var angle: CGFloat = 0
        if rotated {
            // 펼침이면 기기의 세로, 접음이면 기기의 가로(오른쪽)로
            let target: UIInterfaceOrientation = wantPortrait ? .portrait : Self.foldedOrientation
            angle = Self.hardwareAngle(target) - Self.hardwareAngle(current)
        }
        stage.transform = .identity
        stage.bounds = CGRect(origin: .zero, size: rotated ? CGSize(width: b.height, height: b.width) : b.size)
        stage.center = CGPoint(x: b.midX, y: b.midY)
        stage.transform = CGAffineTransform(rotationAngle: angle)
        let inset = view.safeAreaInsets
        let m = max(inset.top, inset.left, inset.bottom, inset.right)
        openView.safeInsets = rotated ? UIEdgeInsets(top: m, left: m, bottom: m, right: m) : inset
        openView.frame = stage.bounds
        closedView.frame = stage.bounds
        picker?.frame = stage.bounds
        layoutSettingsCard()
        openView.layoutIfNeeded()
        fpsLabel.frame = openView.layout.fpsSpot   // 경첩 왼쪽 마디에 새긴 글씨처럼
        if rotated != stageRotated {
            stageRotated = rotated
            if rotated { openView.controls.releaseAll() }
        }
        updateOrientationLock()
    }

    /// 접었을 때의 방향: 카드 슬롯(그림의 위쪽)이 경첩 쪽에 오는 가로 한 방향. 바깥 화면에서 경첩이 어느 쪽인지는 API가 알려 주지 않는다 —
    /// 기본은 가로-왼쪽(홈 쪽이 왼쪽 = 폰처럼 세로로 들었을 때 왼쪽 긴 변이 경첩), 반대면 설정의 "접은 화면 뒤집기"
    /// (2026-10-25 사용자: 가로-오른쪽으로 섰을 때 슬롯이 경첩 반대쪽이었다).
    static var foldedOrientation: UIInterfaceOrientation { Settings.shared.foldedFlip ? .landscapeRight : .landscapeLeft }

    /// 시스템 화면 방향이 기기의 세로에서 돌아간 각도(라디안, 화면 좌표의 시계 방향 = +). 기기를 시계 방향으로 돌리면
    /// landscapeLeft(홈 쪽이 왼쪽) — 기기에 붙은 그림은 시계 방향으로 돌아 보여야 폰을 되돌렸을 때 바로 선다(시뮬레이터로 확인)
    private static func hardwareAngle(_ o: UIInterfaceOrientation) -> CGFloat {
        switch o {
        case .landscapeLeft: return -.pi / 2
        case .landscapeRight: return .pi / 2
        case .portraitUpsideDown: return .pi
        default: return 0
        }
    }

    /// 잠글지 다시 판단: 시스템 방향이 원하는 방향과 맞을 때만 잠근다(안 맞으면 풀어 둬야 요청 · 폰 돌리기로 맞출 수 있다). 접고 펴는 중엔 미룬다
    private func updateOrientationLock() {
        guard !lockSettling, let f = folded, view.bounds.width > 0 else { orientationLocked = false; return }
        let current = view.window?.windowScene?.effectiveGeometry.interfaceOrientation
        orientationLocked = f ? current == Self.foldedOrientation : current?.isPortrait == true
    }

    // ── 접힘 ─────────────────────────────────

    private func computeFolded() -> Bool {
        switch hinge.status {
        case .closed: return true
        case .partial, .open: return false
        case .unknown, .unavailable:
            // 접힘을 모르면 화면 크기로(바깥 화면은 작다) — 듀오에서만. 접히지 않는 기기(작은 아이폰 포함)면 늘 펼친 DS
            return max(view.bounds.width, view.bounds.height) < 760 && hinge.status == .unknown && hinge.canFold
        }
    }

    private func hingeChanged() {
        openView.bent = hinge.isBent
        openView.noCard.foldable = hinge.canFold
        let f = computeFolded()
        guard f != folded else { return }
        let first = folded == nil
        folded = f
        // 접고 펴는 순간: 잠금을 풀고, 새 화면(바깥 ↔ 안쪽)이 자리 잡은 뒤 다시 잠근다
        lockSettling = true
        orientationLocked = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.lockSettling = false
            self?.updateOrientationLock()
        }
        applyOrientation()
        layoutStage()
        if f { enterFolded(animated: !first) } else { enterOpen(animated: !first) }
    }

    /// 지금 상태의 방향(펼침 = 세로, 접음 = 가로)으로 돌려 달라고 한다. 잠금을 먼저 풀고, 판은 도는 동안 감춘다
    private func applyOrientation() {
        guard let scene = view.window?.windowScene, let f = folded else { return }
        let current = scene.effectiveGeometry.interfaceOrientation
        if f ? current == Self.foldedOrientation : current.isPortrait { updateOrientationLock(); return }
        orientationLocked = false
        hideForRotation()
        DispatchQueue.main.async {   // 잠금 해제 · 감춤이 반영된 뒤에
            let mask: UIInterfaceOrientationMask = !f ? .portrait : Self.foldedOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
                NSLog("DuoDS orientation request refused: \(error)")
                DispatchQueue.main.async { self?.revealAfterRotation() }
            }
        }
    }

    /// 도는 모습이 안 보이게 판을 감춘다(검은 바탕만 돈다). 끝내 안 돌면 0.9초 뒤 그냥 보인다
    private func hideForRotation() {
        stage.layer.removeAllAnimations()
        stage.alpha = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.revealAfterRotation() }
    }

    private func revealAfterRotation() {
        guard stage.alpha < 1 else { return }
        UIView.animate(withDuration: 0.2) { self.stage.alpha = 1 }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // 가로 ↔ 세로가 바뀌는 회전이면(요청했든 시스템이 했든) 도는 동안 감춘다
        if (size.width > size.height) != (view.bounds.width > view.bounds.height) { hideForRotation() }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.revealAfterRotation()
            self?.updateOrientationLock()
            // 시스템이 다른 방향으로 돌려 버렸으면(창 · 알림이 잠금을 풀었을 때 등) 다시 돌려 놓는다
            if let self, !self.lockSettling, self.presentedViewController == nil { self.applyOrientation() }
            if let o = self?.view.window?.windowScene?.effectiveGeometry.interfaceOrientation {
                NSLog("DuoDS orientation now: \(o.rawValue) (1 세로 · 3 가로-오른쪽 · 4 가로-왼쪽)")
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyOrientation()
    }

    @objc private func simulateFold() {
        hinge.simulate(folded == true ? .partial : .closed)
    }

    private func enterFolded(animated: Bool) {
        openView.controls.releaseAll()
        touchKeys = 0
        pushKeys()
        closeSettings(animated: false)
        closePicker(animated: false)
        closedView.isHidden = false
        fpsLabel.isHidden = true
        if animated {
            closedView.alpha = 0
            UIView.animate(withDuration: 0.25, animations: { self.closedView.alpha = 1 }) { _ in
                if self.folded == true { self.openView.isHidden = true }
            }
        } else {
            openView.isHidden = true
        }
        guard let s = session else {
            closedView.leds.power = .off
            closedView.caption = "슬롯을 눌러 카트리지를 넣으세요"
            return
        }
        // 켠 적이 있으면 DS처럼 절전(천천히 깜빡임), 아니면 꺼짐
        closedView.leds.power = s.hasRun || s.hasSuspend ? .sleeping : .off
        closedView.caption = "\(s.rom.title)\n\(s.hasRun || s.hasSuspend ? "펼치면 이어서 합니다" : "펼치면 시작합니다")"
        // 실제 DS처럼 뚜껑을 닫고(게임은 대개 절전) 잠깐 뒤 그 자리를 저장
        s.close { [weak self] saved in
            guard let self, self.session === s, self.folded == true else { return }
            if saved {
                self.closedView.caption = "\(s.rom.title)\n자동 저장됨 · 펼치면 이어서"
            }
        }
    }

    private func enterOpen(animated: Bool) {
        closePicker(animated: false)
        closeSettings(animated: false)
        openView.isHidden = false
        fpsLabel.isHidden = !Settings.shared.showFps
        let hide = { self.closedView.isHidden = true; self.closedView.alpha = 1 }
        if animated {
            UIView.animate(withDuration: 0.25, animations: { self.closedView.alpha = 0 }) { _ in hide() }
        } else {
            hide()
        }
        powerOn(fade: true)
    }

    /// 펼친 상태에서 게임을 켠다(카드가 있으면). `fade` = 펼친 순간처럼 화면이 밝아지며 나타남
    private func powerOn(fade: Bool = false) {
        guard let s = session else {
            openView.showsGame = false
            openView.leds.power = .off
            return
        }
        openView.renderer?.frames = s.emulator.frames
        openView.showsGame = true
        openView.leds.power = .on
        if UIApplication.shared.applicationState != .background { s.play() }
        if fade {
            openView.metalView.alpha = 0
            UIView.animate(withDuration: 0.35, delay: 0.05) { self.openView.metalView.alpha = 1 }
        }
    }

    // ── 카트리지 ─────────────────────────────

    private func startSession(_ rom: RomEntry) {
        session?.stop()
        let s = GameSession(rom: rom)
        session = s
        Settings.shared.insertedCartridge = rom.url.lastPathComponent
        s.boot { [weak self] err in
            guard let self, let err, self.session === s else { return }
            self.alert("카트리지를 읽을 수 없습니다", err)
            self.ejectNow()
        }
    }

    private func ejectNow() {
        session?.stop()
        session = nil
        Settings.shared.insertedCartridge = nil
        closedView.showInserted(nil)
        if folded == true {
            closedView.leds.power = .off
            closedView.caption = "슬롯을 눌러 카트리지를 넣으세요"
        } else {
            powerOn()
        }
    }

    private func slotTapped() {
        guard picker == nil else { return }
        if closedView.hasCard {
            let current = session?.rom
            // 빼기 전에 지금 자리를 저장(접을 때 이미 저장했으면 그대로)
            session?.suspend { _ in }
            closedView.eject { [weak self] in
                self?.ejectNow()
                self?.showPicker(current: current)
            }
        } else {
            showPicker()
        }
    }

    private func showPicker(current: RomEntry? = nil) {
        guard picker == nil else { return }
        let p = CartridgePickerView(frame: stage.bounds)
        p.reload(Library.shared.scan(), current: current)
        p.onClose = { [weak self] in self?.closePicker(animated: true) }
        p.onImport = { [weak self] in self?.importROM() }
        p.onDelete = { [weak self] rom in self?.deleteROM(rom) }
        p.onMenuClosed = { [weak self] in self?.applyOrientation() }
        p.onPick = { [weak self] rom, frame in self?.pick(rom, from: frame) }
        stage.addSubview(p)
        picker = p
        p.animateIn()
    }

    private func closePicker(animated: Bool) {
        guard let p = picker else { return }
        picker = nil
        if animated {
            UIView.animate(withDuration: 0.2, animations: { p.alpha = 0 }) { _ in p.removeFromSuperview() }
        } else {
            p.removeFromSuperview()
        }
    }

    private func pick(_ rom: RomEntry, from frame: CGRect) {
        guard let p = picker else { return }
        let kept = p.card(for: rom)
        kept?.alpha = 0
        startSession(rom)
        if folded == true {
            p.animateOut(keeping: nil) { [weak self] in self?.closePicker(animated: false) }
            closedView.caption = ""
            closedView.insert(rom, from: frame) { [weak self] in
                guard let self, self.session?.rom == rom else { return }
                let resume = self.session?.hasSuspend == true
                self.closedView.leds.power = resume ? .sleeping : .off
                self.closedView.caption = "\(rom.title)\n\(resume ? "펼치면 이어서 합니다" : "펼치면 시작합니다")"
            }
        } else {
            // 펼친 채 골랐으면(접힘을 모르는 기기) 바로 켠다
            closedView.showInserted(rom)
            p.animateOut(keeping: nil) { [weak self] in
                self?.closePicker(animated: false)
                self?.powerOn(fade: true)
            }
        }
    }

    private func importROM() {
        let types = [UTType(filenameExtension: "nds") ?? .data, .data]
        let doc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        doc.allowsMultipleSelection = true
        doc.delegate = self
        present(doc, animated: true)
    }

    private func deleteROM(_ rom: RomEntry) {
        let a = UIAlertController(title: "\(rom.title)을(를) 지울까요?", message: "ROM 파일만 지웁니다. 세이브는 남습니다.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in self?.applyOrientation() })
        a.addAction(UIAlertAction(title: "지우기", style: .destructive) { [weak self] _ in
            self?.applyOrientation()
            if self?.session?.rom == rom { self?.ejectNow() }
            try? Library.shared.delete(rom)
            self?.picker?.reload(Library.shared.scan(), current: nil)
        })
        present(a, animated: true)
    }

    // ── 설정 ─────────────────────────────────

    private func openSettings() {
        guard settingsNav == nil, presentedViewController == nil else { return }
        openView.controls.releaseAll()
        if folded != true { session?.pause() }
        let vc = SettingsViewController()
        if let s = session { vc.gameTitle = s.rom.title; vc.gameActions = gameActions(s) }
        vc.onClose = { [weak self] in self?.closeSettings(animated: true) }
        let nav = UINavigationController(rootViewController: vc)
        settingsNav = nav

        // 어둡게 깐 바탕(누르면 닫힘) + 가운데 카드 — 판(stage) 안에 얹어서 판과 같이 돈다
        settingsScrim.backgroundColor = UIColor(white: 0, alpha: 0.45)
        settingsScrim.frame = stage.bounds
        settingsScrim.alpha = 0
        if settingsScrim.allTargets.isEmpty {
            settingsScrim.addAction(UIAction { [weak self] _ in self?.closeSettings(animated: true) }, for: .touchUpInside)
        }
        stage.addSubview(settingsScrim)
        addChild(nav)
        nav.view.layer.cornerRadius = 20
        nav.view.layer.cornerCurve = .continuous
        nav.view.clipsToBounds = true
        stage.addSubview(nav.view)
        layoutSettingsCard()
        nav.didMove(toParent: self)
        nav.view.transform = CGAffineTransform(translationX: 0, y: stage.bounds.height)
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2) {
            self.settingsScrim.alpha = 1
            nav.view.transform = .identity
        }
    }

    private func layoutSettingsCard() {
        guard let nav = settingsNav else { return }
        let b = stage.bounds
        settingsScrim.frame = b
        let w = min(b.width - 24, 560)
        let h = min(b.height - 40, b.height * 0.88)
        nav.view.frame = CGRect(x: (b.width - w) / 2, y: b.height - h - 12, width: w, height: h)
    }

    private func closeSettings(animated: Bool) {
        guard let nav = settingsNav else { return }
        settingsNav = nil
        let finish = {
            nav.willMove(toParent: nil)
            nav.view.removeFromSuperview()
            nav.removeFromParent()
            self.settingsScrim.removeFromSuperview()
            nav.view.transform = .identity
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: {
                self.settingsScrim.alpha = 0
                nav.view.transform = CGAffineTransform(translationX: 0, y: self.stage.bounds.height)
            }) { _ in finish() }
        } else {
            finish()
        }
        settingsClosed()
    }

    private func settingsClosed() {
        applyOrientation()
        if folded == true {
            closedView.openCover(false)
        } else if presentedViewController == nil {
            powerOn()
        }
    }

    private func gameActions(_ s: GameSession) -> [(title: String, destructive: Bool, run: () -> Void)] {
        var list: [(title: String, destructive: Bool, run: () -> Void)] = []
        list.append(("빠른 저장", false, { [weak self] in
            s.emulator.saveState(to: s.rom.stateURL) { ok in self?.toast(ok ? "저장했습니다" : "저장하지 못했습니다") }
        }))
        if s.rom.hasState {
            list.append(("빠른 불러오기", false, { [weak self] in
                s.emulator.loadState(from: s.rom.stateURL) { ok in self?.toast(ok ? "불러왔습니다" : "불러오지 못했습니다") }
            }))
        }
        list.append((s.emulator.fastForward ? "빨리 감기 끄기" : "빨리 감기", false, { s.emulator.fastForward.toggle() }))
        list.append(("위 · 아래 화면 바꾸기", false, { [weak self] in
            guard let self else { return }
            self.swapped.toggle()
            self.openView.swapped = self.swapped
        }))
        list.append(("처음부터 다시", true, { [weak self] in
            s.restart()
            self?.toast("처음부터 시작합니다")
        }))
        list.append(("카트리지 빼기", true, { [weak self] in
            s.suspend { _ in }
            self?.ejectNow()
        }))
        return list
    }

    @objc private func settingsChanged() {
        let theme = ConsoleTheme.current
        openView.theme = theme
        closedView.theme = theme
        openView.layoutStyle = Settings.shared.layoutStyle
        fpsLabel.textColor = theme.letter.withAlphaComponent(0.9)
        if folded == true { applyOrientation() }   // "접은 화면 뒤집기"가 바뀌었을 수 있다
        openView.renderer?.look = Settings.shared.screenLook
        session?.emulator.setVolume(Settings.shared.volume)
        session?.emulator.setScale3D(Settings.shared.scale3D.rawValue)
        fpsLabel.isHidden = !Settings.shared.showFps || folded == true
        fpsTimer?.invalidate()
        fpsTimer = nil
        if Settings.shared.showFps {
            fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let s = self.session else { return }
                self.fpsLabel.text = String(format: "%.1f FPS", s.emulator.measuredFps)
            }
        }
    }

    /// 무선 LED: 근거리 방에 있거나, 게임이 인터넷(WFC)과 주고받는 동안
    @objc private func wirelessChanged() {
        let on = Wireless.shared.state != .none || Internet.shared.active
        openView.leds.wireless = on
        closedView.leds.wireless = on
    }

    // ── 입력 · 앱 상태 ────────────────────────

    private func pushKeys() {
        session?.emulator.setKeys(folded == true ? 0 : touchKeys | controller.keys)
    }

    @objc private func willResign() {
        openView.controls.releaseAll()
        if folded == false { session?.suspend { _ in } }
    }

    @objc private func didBecomeActive() {
        if folded == false && presentedViewController == nil { powerOn() }
    }

    private func toast(_ text: String) {
        let l = UILabel()
        l.text = "  \(text)  "
        l.font = .systemFont(ofSize: 14, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = UIColor(white: 0, alpha: 0.7)
        l.layer.cornerRadius = 10
        l.layer.masksToBounds = true
        l.sizeToFit()
        l.frame.size.height = 32
        let top = openView.layout.top
        l.center = CGPoint(x: top.midX, y: top.minY + 30)
        stage.addSubview(l)
        UIView.animate(withDuration: 0.3, delay: 1.2, options: []) { l.alpha = 0 } completion: { _ in l.removeFromSuperview() }
    }

    /// 알림(드물게 — 오류). 무엇이든 띄우면 시스템이 방향 잠금을 풀어 돌아갈 수 있어서, 닫힐 때 방향을 다시 세운다
    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "확인", style: .default) { [weak self] _ in self?.applyOrientation() })
        present(a, animated: true)
    }

    /// 파일 앱의 "DuoS로 열기"로 받은 ROM: 가져와서, 접혀 있으면 고르기 화면을 띄운다
    func open(_ urls: [URL]) {
        var imported: RomEntry?
        for url in urls { if let rom = try? Library.shared.importROM(from: url) { imported = rom } }
        guard imported != nil else { return }
        if folded == true && picker == nil && !closedView.hasCard { showPicker() }
        picker?.reload(Library.shared.scan(), current: imported)
    }
}

extension ConsoleViewController: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        applyOrientation()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        applyOrientation()
        var failed: [String] = []
        for url in urls {
            do { _ = try Library.shared.importROM(from: url) } catch { failed.append(url.lastPathComponent) }
        }
        picker?.reload(Library.shared.scan(), current: nil)
        if !failed.isEmpty { alert("가져오지 못한 파일", failed.joined(separator: "\n")) }
    }
}
