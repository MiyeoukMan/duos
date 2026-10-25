import GameController

/// 블루투스 컨트롤러 · 하드웨어 키보드 → DS 버튼.
/// 컨트롤러 버튼은 이름이 아니라 자리로 맞춘다(DS처럼 A가 오른쪽): 엑스박스 B → A, A → B, Y → X, X → Y.
/// 닌텐도 프로 컨트롤러는 이름과 자리가 같아서 그대로 맞는다.
final class ControllerInput {
    /// 버튼이 바뀔 때
    var onKeys: ((UInt32) -> Void)?
    /// 컨트롤러가 붙거나 떨어질 때(붙어 있으면 화면 버튼을 숨긴다)
    var onConnectionChange: ((Bool) -> Void)?

    private var padKeys: UInt32 = 0
    private var keyboardKeys: UInt32 = 0
    private(set) var hasController = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: .GCControllerDidConnect, object: nil)
        nc.addObserver(self, selector: #selector(refresh), name: .GCControllerDidDisconnect, object: nil)
        nc.addObserver(self, selector: #selector(refresh), name: .GCKeyboardDidConnect, object: nil)
        refresh()
    }

    var keys: UInt32 { padKeys | keyboardKeys }

    @objc private func refresh() {
        for c in GCController.controllers() {
            c.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in self?.read(pad) }
        }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] kb, _, _, _ in self?.read(kb) }
        let has = GCController.controllers().contains { $0.extendedGamepad != nil }
        if has != hasController {
            hasController = has
            onConnectionChange?(has)
        }
        if !has { padKeys = 0; onKeys?(keys) }
    }

    private func read(_ p: GCExtendedGamepad) {
        var k: UInt32 = 0
        func on(_ b: GCControllerButtonInput?, _ key: Int) { if b?.isPressed == true { k |= UInt32(key) } }
        let nintendo = p.controller?.productCategory.contains("Switch") == true || p.controller?.productCategory.contains("Nintendo") == true
        if nintendo {
            on(p.buttonA, DS_KEY_A); on(p.buttonB, DS_KEY_B); on(p.buttonX, DS_KEY_X); on(p.buttonY, DS_KEY_Y)
        } else {
            on(p.buttonB, DS_KEY_A); on(p.buttonA, DS_KEY_B); on(p.buttonY, DS_KEY_X); on(p.buttonX, DS_KEY_Y)
        }
        on(p.leftShoulder, DS_KEY_L); on(p.rightShoulder, DS_KEY_R)
        on(p.leftTrigger, DS_KEY_L); on(p.rightTrigger, DS_KEY_R)
        on(p.buttonMenu, DS_KEY_START); on(p.buttonOptions, DS_KEY_SELECT)
        on(p.dpad.up, DS_KEY_UP); on(p.dpad.down, DS_KEY_DOWN); on(p.dpad.left, DS_KEY_LEFT); on(p.dpad.right, DS_KEY_RIGHT)
        let s = p.leftThumbstick
        if s.yAxis.value > 0.5 { k |= UInt32(DS_KEY_UP) }
        if s.yAxis.value < -0.5 { k |= UInt32(DS_KEY_DOWN) }
        if s.xAxis.value < -0.5 { k |= UInt32(DS_KEY_LEFT) }
        if s.xAxis.value > 0.5 { k |= UInt32(DS_KEY_RIGHT) }
        if k != padKeys {
            padKeys = k
            onKeys?(keys)
        }
    }

    /// 키보드: 화살표 · X(A) · Z(B) · S(X) · A(Y) · Q(L) · W(R) · 엔터(START) · 오른쪽 시프트(SELECT)
    private func read(_ kb: GCKeyboardInput) {
        var k: UInt32 = 0
        func on(_ code: GCKeyCode, _ key: Int) { if kb.button(forKeyCode: code)?.isPressed == true { k |= UInt32(key) } }
        on(.upArrow, DS_KEY_UP); on(.downArrow, DS_KEY_DOWN); on(.leftArrow, DS_KEY_LEFT); on(.rightArrow, DS_KEY_RIGHT)
        on(.keyX, DS_KEY_A); on(.keyZ, DS_KEY_B); on(.keyS, DS_KEY_X); on(.keyA, DS_KEY_Y)
        on(.keyQ, DS_KEY_L); on(.keyW, DS_KEY_R)
        on(.returnOrEnter, DS_KEY_START); on(.rightShift, DS_KEY_SELECT)
        if k != keyboardKeys {
            keyboardKeys = k
            onKeys?(keys)
        }
    }
}
