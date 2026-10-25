import UIKit

/// 설정 창(펼친 DS의 SETTINGS 버튼 · 접은 뒷면의 배터리 덮개). 게임 중이면 맨 위에 게임 메뉴.
/// 따로 띄우는 창(시트)이 아니라 게임 화면 위에 얹는 카드다(ConsoleViewController.openSettings) — 시트를 띄우면 시스템이 화면 방향 잠금을 풀어 버린다.
/// 닫기는 `onClose`(카드를 걷어 내는 쪽이 한다).
final class SettingsViewController: UITableViewController {
    var onClose: (() -> Void)?
    /// 게임 중일 때 맨 위에 보이는 일(빠른 저장 등). 누르면 창을 닫고 한다
    var gameActions: [(title: String, destructive: Bool, run: () -> Void)] = []
    var gameTitle: String?
    private let s = Settings.shared

    private enum Row {
        case licenses, source, wireless, internet, theme, layout, foldedFlip, scale3D, filter, tone, lcdGrid, frameBlend, showFps, haptics, volume, nickname, language, birthday, color, about
    }

    private let sections: [(String, [Row], String?)] = [
        ("통신", [.wireless, .internet], nil),
        ("화면", [.scale3D, .filter, .tone, .lcdGrid, .frameBlend, .showFps],
         "3D 해상도는 3D 폴리곤을 그만큼 높은 해상도로 다시 그립니다(2D 그림은 그대로) — 3D가 보이는 화면엔 확대 방식 대신 이 그림이 쓰입니다. MetalFX는 3D 게임의 계단 같은 외곽선을 부드럽게, 도트 다듬기는 2D 도트 그림의 계단을 다듬습니다. 잔상은 깜빡이는 반투명을 부드럽게 하지만 빨리 움직이면 살짝 번집니다."),
        ("본체", [.theme, .layout, .foldedFlip, .haptics], "접었을 때 카드 슬롯이 경첩 반대쪽에 보이면 \"접은 화면 뒤집기\"를 켜세요."),
        ("소리", [.volume], nil),
        ("DS 본체", [.nickname, .language, .birthday, .color], "다음에 게임을 켤 때부터 적용됩니다."),
        ("정보", [.about, .licenses] + (Settings.sourceCodeURL == nil ? [] : [.source]), nil),
    ]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "설정"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.onClose?()
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: Wireless.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()   // 인터넷 화면에서 서버를 바꾸고 돌아올 때
    }

    private var hasGame: Bool { !gameActions.isEmpty }
    private func section(_ i: Int) -> Int { hasGame ? i - 1 : i }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count + (hasGame ? 1 : 0) }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        hasGame && section == 0 ? gameActions.count : sections[self.section(section)].1.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        hasGame && section == 0 ? (gameTitle ?? "게임") : sections[self.section(section)].0
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        hasGame && section == 0 ? "듀오를 접으면 그 자리가 자동으로 저장되고, 펼치면 이어서 합니다." : sections[self.section(section)].2
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if !(hasGame && indexPath.section == 0) {
            switch sections[section(indexPath.section)].1[indexPath.row] {
            case .wireless:
                tableView.deselectRow(at: indexPath, animated: true)
                navigationController?.pushViewController(WirelessViewController(), animated: true)
                return
            case .internet:
                tableView.deselectRow(at: indexPath, animated: true)
                navigationController?.pushViewController(InternetViewController(gameLoaded: hasGame), animated: true)
                return
            case .licenses:
                tableView.deselectRow(at: indexPath, animated: true)
                navigationController?.pushViewController(LicensesViewController(), animated: true)
                return
            case .source:
                tableView.deselectRow(at: indexPath, animated: true)
                if let url = Settings.sourceCodeURL { UIApplication.shared.open(url) }
                return
            default:
                break
            }
        }
        guard hasGame && indexPath.section == 0 else { return }
        let action = gameActions[indexPath.row].run
        onClose?()
        action()
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var c = cell.defaultContentConfiguration()
        if hasGame && indexPath.section == 0 {
            let a = gameActions[indexPath.row]
            c.text = a.title
            c.textProperties.color = a.destructive ? .systemRed : .tintColor
            cell.selectionStyle = .default
            cell.contentConfiguration = c
            return cell
        }
        switch sections[section(indexPath.section)].1[indexPath.row] {
        case .scale3D:
            c.text = "3D 해상도"
            cell.accessoryView = menuButton(Settings.Scale3D.allCases.map { k in
                (k.title, k == s.scale3D, { [weak self] in self?.s.scale3D = k })
            })
        case .filter:
            c.text = "확대 방식"
            cell.accessoryView = menuButton(Settings.Filter.available.map { f in
                (f.title, f == s.filter, { [weak self] in self?.s.filter = f })
            })
        case .tone:
            c.text = "색감"
            cell.accessoryView = menuButton(Settings.Tone.allCases.map { t in
                (t.title, t == s.tone, { [weak self] in self?.s.tone = t })
            })
        case .lcdGrid:
            c.text = "LCD 격자"
            cell.accessoryView = menuButton(Settings.Grid.allCases.map { g in
                (g.title, g == s.lcdGrid, { [weak self] in self?.s.lcdGrid = g })
            })
        case .frameBlend:
            c.text = "잔상"
            cell.accessoryView = toggle(s.frameBlend) { [weak self] v in self?.s.frameBlend = v }
        case .theme:
            c.text = "본체 색"
            cell.accessoryView = menuButton(ConsoleTheme.all.map { t in
                (t.name, t.id == s.themeID, { [weak self] in self?.s.themeID = t.id })
            })
        case .licenses:
            c.text = "오픈 소스 라이선스"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .source:
            c.text = "소스 코드(GPL-3.0)"
            c.secondaryText = Settings.sourceCodeURL?.host()
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .wireless:
            c.text = "무선 통신"
            let st = Wireless.shared.state
            c.secondaryText = st == .none ? "꺼짐" : st == .host ? "방장" : "참가 중"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .internet:
            c.text = "온라인 플레이"
            c.secondaryText = Internet.shared.invalidCustom ? "주소가 틀림" : s.wfcServer.title
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .layout:
            c.text = "펼친 화면 배치"
            cell.accessoryView = menuButton(Settings.LayoutStyle.allCases.map { st in
                (st.title, st == s.layoutStyle, { [weak self] in self?.s.layoutStyle = st })
            })
        case .foldedFlip:
            c.text = "접은 화면 뒤집기"
            cell.accessoryView = toggle(s.foldedFlip) { [weak self] v in self?.s.foldedFlip = v }
        case .showFps:
            c.text = "초당 프레임 표시"
            cell.accessoryView = toggle(s.showFps) { [weak self] v in self?.s.showFps = v }
        case .haptics:
            c.text = "버튼 진동"
            cell.accessoryView = toggle(s.haptics) { [weak self] v in self?.s.haptics = v }
        case .volume:
            c.text = "음량"
            cell.accessoryView = slider(value: s.volume, min: 0, max: 1) { [weak self] v in self?.s.volume = v }
        case .nickname:
            c.text = "이름"
            let field = UITextField(frame: CGRect(x: 0, y: 0, width: 160, height: 30))
            field.text = s.nickname
            field.textAlignment = .right
            field.placeholder = "최대 10글자"
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.addAction(UIAction { [weak self, weak field] _ in self?.s.nickname = field?.text ?? "" }, for: .editingChanged)
            field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
            cell.accessoryView = field
        case .language:
            c.text = "언어"
            cell.accessoryView = menuButton(Settings.languageNames.enumerated().map { i, name in
                (name, i == s.language, { [weak self] in self?.s.language = i })
            })
        case .birthday:
            c.text = "생일"
            let months = menuButton((1...12).map { m in ("\(m)월", m == s.birthdayMonth, { [weak self] in self?.s.birthdayMonth = m }) })
            let days = menuButton((1...31).map { d in ("\(d)일", d == s.birthdayDay, { [weak self] in self?.s.birthdayDay = d }) })
            let stack = UIStackView(arrangedSubviews: [months, days])
            stack.spacing = 4
            stack.frame = CGRect(x: 0, y: 0, width: 150, height: 30)
            cell.accessoryView = stack
        case .color:
            c.text = "좋아하는 색"
            cell.accessoryView = menuButton(Self.colorNames.enumerated().map { i, name in
                (name, i == s.favoriteColor, { [weak self] in self?.s.favoriteColor = i })
            })
        case .about:
            c = UIListContentConfiguration.subtitleCell()
            c.text = "DuoS"
            c.secondaryText = "에뮬레이션 코어: melonDS 1.1 (GPL-3.0) — melonds.kuribo64.net\n바이오스 · 펌웨어는 melonDS의 FreeBIOS와 자체 생성 펌웨어를 씁니다. 게임 롬은 들어 있지 않습니다."
            c.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = c
        return cell
    }

    static let colorNames = ["회색", "갈색", "빨강", "분홍", "주황", "노랑", "연두", "초록", "진초록", "청록", "하늘", "파랑", "남색", "보라", "자주", "자홍"]

    private func toggle(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { [weak sw] _ in change(sw?.isOn ?? false) }, for: .valueChanged)
        return sw
    }

    private func slider(value: Float, min: Float, max: Float, _ change: @escaping (Float) -> Void) -> UISlider {
        let sl = UISlider(frame: CGRect(x: 0, y: 0, width: 150, height: 30))
        sl.minimumValue = min
        sl.maximumValue = max
        sl.value = value
        sl.addAction(UIAction { [weak sl] _ in change(sl?.value ?? 0) }, for: .valueChanged)
        return sl
    }

    private func menuButton(_ items: [(String, Bool, () -> Void)]) -> UIButton {
        let b = UIButton(type: .system)
        b.showsMenuAsPrimaryAction = true
        b.changesSelectionAsPrimaryAction = true
        b.menu = UIMenu(children: items.map { title, on, act in
            UIAction(title: title, state: on ? .on : .off) { _ in act() }
        })
        b.sizeToFit()
        b.frame.size.width = max(b.frame.width, 70)
        return b
    }
}
