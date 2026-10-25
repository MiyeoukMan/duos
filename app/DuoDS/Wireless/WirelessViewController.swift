import UIKit

/// 무선 통신 화면(설정 › 무선 통신): 방 만들기 · 주변 방(Bonjour) · IP로 참가 · 참가자 목록 · 나가기.
/// 알림창(UIAlertController)은 쓰지 않는다 — 무엇이든 띄우면 시스템이 화면 방향 잠금을 풀어 화면이 돌아간다. 입력 · 진행 · 실패 안내는 모두 표 안에.
final class WirelessViewController: UITableViewController {
    private let w = Wireless.shared
    private var busy = false
    /// 마지막 결과 안내(실패 이유 등) — 상태 칸 아래에
    private var message: String?
    private let ipField = UITextField()

    private enum Section { case status, players, host, rooms, direct }
    private var sections: [Section] {
        w.state == .none ? [.status, .host, .rooms, .direct] : [.status, .players]
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "무선 통신"
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Wireless.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        w.startBrowsing()
        w.refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        w.stopBrowsing()
    }

    @objc private func changed() { tableView.reloadData() }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .status: return w.state == .none ? 2 : 3
        case .players: return max(w.players.count, 1)
        case .host: return 2
        case .rooms: return max(w.rooms.count, 1)
        case .direct: return 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .status: return "상태"
        case .players: return "참가자 \(w.players.count)/\(w.maxPlayers)"
        case .host: return "방 만들기"
        case .rooms: return "주변 방(같은 Wi-Fi의 DuoS)"
        case .direct: return "직접 참가"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch sections[section] {
        case .status:
            if let m = message { return m }
            return w.state == .none ? nil : "양쪽에 같은 게임을 꽂고, 게임 안의 통신(대전 · 협력) 메뉴로 들어가세요. 다운로드 플레이는 지원하지 않습니다."
        case .rooms:
            if let problem = w.bonjourProblem {
                return "주변 방 찾기를 쓸 수 없습니다(\(problem)). 설정 › 개인정보 보호 › 로컬 네트워크에서 DuoS를 켜거나, 아래 \"IP 주소로 참가\"를 쓰세요."
            }
            return "방이 안 보이면 두 기기가 같은 Wi-Fi인지, 설정 › 개인정보 보호 › 로컬 네트워크에서 DuoS가 켜져 있는지 확인하세요."
        case .direct:
            return "맥의 melonDS가 연 방에 붙을 때는 그 맥의 IP를 넣으세요. 반대로 melonDS에서 이 기기에 붙으려면 \"이 기기 IP\"를 직접 연결(Direct connect)에 넣습니다. melonDS는 DuoS와 같은 버전(코어)이어야 합니다."
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var c = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        switch sections[indexPath.section] {
        case .status:
            switch (w.state, indexPath.row) {
            case (_, 0):
                c.text = "무선"
                c.secondaryText = w.state == .none ? "꺼짐" : w.state == .host ? "방장" : "참가 중"
            case (_, 1):
                c.text = "이 기기 IP"
                c.secondaryText = w.localIPv4 ?? "Wi-Fi 없음"
            default:
                c = UIListContentConfiguration.cell()
                c.text = w.state == .host ? "방 닫기" : "나가기"
                c.textProperties.color = .systemRed
                cell.selectionStyle = .default
            }
        case .players:
            if w.players.isEmpty {
                c.text = "연결 중…"
            } else {
                let p = w.players[indexPath.row]
                c.text = Wireless.name(p) + (p.is_local != 0 ? " (나)" : "")
                let role = p.status == 2 ? "방장" : p.status == 3 ? "연결 중" : p.status == 4 ? "끊김" : "참가"
                c.secondaryText = p.is_local != 0 ? role : "\(role) · \(p.ping_ms)ms"
            }
        case .host:
            if indexPath.row == 0 {
                c.text = "최대 인원"
                c.secondaryText = "\(Settings.shared.lanMaxPlayers)명"
                let st = UIStepper()
                st.minimumValue = 2
                st.maximumValue = 16
                st.value = Double(Settings.shared.lanMaxPlayers)
                st.addAction(UIAction { [weak self, weak st] _ in
                    Settings.shared.lanMaxPlayers = Int(st?.value ?? 4)
                    self?.tableView.reloadData()
                }, for: .valueChanged)
                cell.accessoryView = st
            } else {
                c = UIListContentConfiguration.cell()
                c.text = busy ? "방 만드는 중…" : "방 만들기(이름: \(w.playerName))"
                c.textProperties.color = .tintColor
                cell.selectionStyle = .default
            }
        case .rooms:
            if w.rooms.isEmpty {
                c.text = "찾는 중…"
                c.textProperties.color = .secondaryLabel
            } else {
                let r = w.rooms[indexPath.row]
                c.text = r.name
                c.secondaryText = r.address == nil ? "주소 확인 중" : r.maxPlayers > 0 ? "\(r.players)/\(r.maxPlayers)명" : r.address
                cell.selectionStyle = .default
                cell.accessoryType = .disclosureIndicator
            }
        case .direct:
            if indexPath.row == 0 {
                c.text = "방장 IP"
                ipField.placeholder = "예: 192.168.0.12"
                if ipField.text?.isEmpty != false { ipField.text = UserDefaults.standard.string(forKey: "lanLastIP") }
                ipField.keyboardType = .decimalPad
                ipField.textAlignment = .right
                ipField.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
                cell.accessoryView = ipField
            } else {
                c = UIListContentConfiguration.cell()
                c.text = busy ? "참가하는 중…" : "이 IP로 참가"
                c.textProperties.color = .tintColor
                cell.selectionStyle = .default
            }
        }
        cell.contentConfiguration = c
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        switch sections[indexPath.section] {
        case .status where indexPath.row == 2:
            w.leave()
        case .host where indexPath.row == 1:
            busy = true
            tableView.reloadData()
            w.host(maxPlayers: Settings.shared.lanMaxPlayers) { [weak self] ok in
                self?.busy = false
                self?.message = ok ? nil : "방을 만들 수 없습니다 — 다른 앱이 7064 포트를 쓰고 있거나 Wi-Fi가 꺼져 있을 수 있습니다."
                self?.tableView.reloadData()
            }
        case .rooms:
            guard indexPath.row < w.rooms.count, let ip = w.rooms[indexPath.row].address else { return }
            join(ip)
        case .direct where indexPath.row == 1:
            ipField.resignFirstResponder()
            let ip = ipField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            if ip.isEmpty { message = "방장 IP를 넣으세요."; tableView.reloadData() } else { join(ip) }
        default:
            break
        }
    }

    private func join(_ address: String) {
        busy = true
        message = "\(address)에 참가하는 중…"
        tableView.reloadData()
        w.join(address: address) { [weak self] ok in
            self?.busy = false
            if ok { UserDefaults.standard.set(address, forKey: "lanLastIP") }
            self?.message = ok ? nil : "참가하지 못했습니다 — \(address)에 방이 없거나, 버전이 다르거나, 방이 가득 찼습니다."
            self?.tableView.reloadData()
        }
    }
}
