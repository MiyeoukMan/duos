import UIKit

/// 인터넷 화면(설정 › 인터넷(WFC)): 서버 고르기(Wiimmfi · Kaeru WFC · 직접 입력) · 연결 시험 · 게임이 주고받은 것 · Nintendo WFC 설정 지우기.
/// 무선 통신 화면처럼 알림창 없이 표 안에서 다 한다(띄우면 시스템이 화면 방향 잠금을 푼다).
final class InternetViewController: UITableViewController {
    private let net = Internet.shared
    private let s = Settings.shared
    /// 카트리지가 꽂혀 있으면(게임이 켜져 있으면) Nintendo WFC 설정을 지울 수 없다 — 켜진 게임이 옛 설정을 다시 쓴다
    private let gameLoaded: Bool
    private let dnsField = UITextField()
    private var probeText: String?
    private var probing = false
    private var confirmReset = false

    private enum Section { case server, status, log, wfc }
    private var sections: [Section] { net.dns != nil && !net.invalidCustom ? [.server, .status, .log, .wfc] : [.server, .log, .wfc] }

    init(gameLoaded: Bool) {
        self.gameLoaded = gameLoaded
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "온라인 플레이"
        dnsField.placeholder = "예: 95.217.77.151"
        dnsField.keyboardType = .decimalPad
        dnsField.textAlignment = .right
        dnsField.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        dnsField.text = s.wfcCustomDNS
        dnsField.addAction(UIAction { [weak self] _ in self?.customChanged() }, for: .editingChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(statusChanged), name: Internet.didChange, object: nil)
    }

    /// 상태 칸만 다시 그린다(서버 칸의 입력 칸은 건드리지 않게). 칸 수가 바뀌는 중이면 바꾸는 쪽이 그린다
    @objc private func statusChanged() {
        guard tableView.numberOfSections == sections.count, let i = sections.firstIndex(of: .status) else { return }
        tableView.reloadSections(IndexSet(integer: i), with: .none)
    }

    /// 직접 입력: 맞는 주소가 들어가는 대로 바로 쓴다(틀리면 인터넷은 꺼진 채). 입력 칸이 키보드를 잃지 않게 표 전체는 다시 그리지 않는다
    private func customChanged() {
        s.wfcCustomDNS = dnsField.text ?? ""
        probeText = nil
        net.apply()
        // 표가 지금 보이는 칸 수와 비교한다(주소를 바꾼 뒤의 sections로는 "전"을 알 수 없다)
        let shown = tableView.numberOfSections, want = sections.count
        if shown != want {
            tableView.performBatchUpdates {
                if want > shown { tableView.insertSections(IndexSet(integer: 1), with: .fade) }
                else { tableView.deleteSections(IndexSet(integer: 1), with: .fade) }
            }
        }
        tableView.cellForRow(at: IndexPath(row: Internet.Server.allCases.count, section: 0))?.contentConfiguration = customRow()
    }

    private func customRow() -> UIListContentConfiguration {
        var c = UIListContentConfiguration.valueCell()
        let bad = net.invalidCustom && !(dnsField.text ?? "").isEmpty
        c.text = bad ? "주소가 틀림" : "서버 DNS"
        c.textProperties.color = bad ? .systemRed : .label
        return c
    }

    // ── 표 ──

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .server: return Internet.Server.allCases.count + (s.wfcServer == .custom ? 1 : 0)
        case .status: return 4
        case .log: return 1
        case .wfc: return 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .server: return "서버"
        case .status: return "상태"
        case .log: return "원인 찾기"
        case .wfc: return "온라인 접속 정보"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .server:
            if s.wfcServer == .custom { return "서버의 DNS 주소(IPv4)를 넣으면 바로 씁니다. 맞는 주소가 들어갈 때까지 인터넷은 꺼져 있습니다." }
            if s.wfcServer == .off { return "게임의 온라인(Wi-Fi 접속) 메뉴에 연결하지 않습니다." }
            return "게임이 묻는 서버 주소(DNS)를 모두 이 서버로 보냅니다. 게임 안의 Wi-Fi 접속 설정은 처음 그대로(접속점 melonAP · DNS 자동) 두면 됩니다. 서버가 지원하는 게임만 접속됩니다."
        case .status:
            return "\"연결 시험\"은 서버에 nas.nintendowifi.net을 물어봅니다. 게임 안의 \"접속 시험\"도 같은 길로 갑니다."
        case .log:
            return "게임이 붙은 곳과 서버의 답(DNS · 연결 · GameSpy 로그인 메시지)을 시각과 함께 남깁니다. \"복사\"로 꺼내거나, 맥에 연결해 Finder의 기기 › 파일 › DuoS › Logs에서 wfc-log.txt를 가져올 수 있습니다. 로그인 토큰이 들어 있으니 아무 데나 올리지 마세요."
        case .wfc:
            if gameLoaded { return "카트리지를 뺀 상태에서 지울 수 있습니다(켜진 게임이 옛 설정을 다시 씁니다)." }
            return "처음 접속할 때 게임이 이 기기의 접속 ID를 만들어 남깁니다. 서버를 바꾸면 친구 코드를 다시 등록해야 할 수 있고, 서버가 막았다는 오류(23917 등)가 나면 설정을 지운 뒤 다시 접속해 보세요."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        switch sections[indexPath.section] {
        case .server:
            let all = Internet.Server.allCases
            if indexPath.row < all.count {
                let server = all[indexPath.row]
                c.text = server.title
                c.secondaryText = server.presetDNS
                cell.accessoryType = server == s.wfcServer ? .checkmark : .none
                cell.selectionStyle = .default
            } else {
                c = customRow()
                cell.accessoryView = dnsField
            }
        case .status:
            let st = net.status
            switch indexPath.row {
            case 0:
                c.text = "서버 DNS"
                c.secondaryText = net.dns
            case 1:
                c = UIListContentConfiguration.valueCell()
                c.text = probing ? "묻는 중…" : "연결 시험"
                c.textProperties.color = .tintColor
                c.secondaryText = probeText
                cell.selectionStyle = .default
            case 2:
                c.text = "최근 게임 접속"
                if st.dns_queries == 0 {
                    c.secondaryText = "아직 없음"
                } else {
                    c.secondaryText = net.lastName + (st.last_address != 0 ? " → \(Internet.ipString(st.last_address))" : " → 답 없음")
                }
                c.secondaryTextProperties.numberOfLines = 2
            default:
                c.text = "주고받은 양"
                c.secondaryText = "보냄 \(Internet.bytesString(st.bytes_out)) · 받음 \(Internet.bytesString(st.bytes_in))"
                    + (st.dns_failures > 0 ? " · 실패 \(st.dns_failures)" : "")
            }
        case .log:
            c.text = "접속 기록"
            let size = (try? FileManager.default.attributesOfItem(atPath: Library.shared.wfcLogURL.path)[.size] as? Int64) ?? 0
            c.secondaryText = ByteCountFormatter.string(fromByteCount: size, countStyle: .binary)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .wfc:
            if indexPath.row == 0 {
                c.text = "이 기기의 접속 ID"
                c.secondaryText = ds_wfc_configured() != 0 ? "있음" : "없음(처음 접속할 때 만듦)"
            } else {
                c = UIListContentConfiguration.cell()
                c.text = confirmReset ? "한 번 더 누르면 지웁니다" : "온라인 접속 정보 지우기"
                c.textProperties.color = gameLoaded ? .tertiaryLabel : .systemRed
                cell.selectionStyle = gameLoaded ? .none : .default
            }
        }
        cell.contentConfiguration = c
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .server:
            let all = Internet.Server.allCases
            guard indexPath.row < all.count else { dnsField.becomeFirstResponder(); return }
            let server = all[indexPath.row]
            guard server != s.wfcServer else { return }
            s.wfcServer = server
            probeText = nil
            net.apply()
            tableView.reloadData()
            if server == .custom && s.wfcCustomDNS.isEmpty { dnsField.becomeFirstResponder() } else { dnsField.resignFirstResponder() }
        case .status where indexPath.row == 1:
            guard !probing else { return }
            probing = true
            probeText = nil
            statusChanged()
            net.probe { [weak self] address, ms in
                guard let self else { return }
                self.probing = false
                self.probeText = address.map { "응답함 · \($0) · \(ms)ms" } ?? "응답 없음"
                self.statusChanged()
            }
        case .log:
            navigationController?.pushViewController(NetLogViewController(), animated: true)
        case .wfc where indexPath.row == 1:
            guard !gameLoaded else { return }
            if confirmReset {
                ds_wfc_reset()
                confirmReset = false
            } else {
                confirmReset = true
            }
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .none)
        default:
            break
        }
    }
}
