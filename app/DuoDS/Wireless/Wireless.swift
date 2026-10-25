import Foundation
import Network

/// DS 근거리 무선(DuoDS끼리 · 맥의 melonDS와) — melonDS LAN(ENet, UDP 7064) 세션을 앱에서 다룬다.
/// - 방 찾기: melonDS는 UDP 방송(7063)으로 찾지만 아이폰은 특별 권한 없이는 방송을 막는다 → DuoDS끼리는 Bonjour(_duods._udp)로 알리고 찾는다
///   (Network 프레임워크 — 알림은 7065에 빈 리스너를 열어 그 이름표로 붙이고, 찾은 방은 잠깐 연결해 상대 IP를 알아낸다).
///   맥 melonDS와는 IP를 직접 넣어 붙는다(이 기기의 IP를 화면에 보여 준다).
/// - 연결 돌보기: 세션이 있는 동안 전용 큐에서 초당 60번 ds_lan_process(게임이 멈춰 있어도 연결이 끊기지 않게).
/// - 게임 안의 통신은 에뮬레이터 스레드가 MP_* 로 직접 주고받는다(코어 안에서 같은 잠금).
final class Wireless {
    static let shared = Wireless()
    static let didChange = Notification.Name("DuoDSWirelessDidChange")
    static let serviceType = "_duods._udp."
    static let port: Int32 = 7064

    struct Room {
        let name: String        // Bonjour 이름(방장 이름)
        var players: Int
        var maxPlayers: Int
        var address: String?    // 풀린 IPv4
        let endpoint: NWEndpoint
    }

    enum State { case none, host, client }

    private(set) var state: State = .none
    private(set) var players: [DSLanPlayer] = []
    private(set) var maxPlayers = 0
    private(set) var rooms: [Room] = []

    private let queue = DispatchQueue(label: "DuoDS.wireless")
    private var pump: DispatchSourceTimer?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private var refreshTimer: Timer?
    /// Bonjour가 막혔을 때의 이유(로컬 네트워크 권한 등) — 화면에 보여 준다
    private(set) var bonjourProblem: String?

    var playerName: String {
        // 플레이어 이름 = DS 본체 이름(UTF-8 31바이트 안으로 — 글자 중간에서 자르지 않게)
        var s = Settings.shared.nickname.isEmpty ? "DuoS" : Settings.shared.nickname
        while s.utf8.count > 31 { s.removeLast() }
        return s
    }

    // ── 방 만들기 · 참가 · 나가기 ───────────────

    func host(maxPlayers: Int, done: @escaping (Bool) -> Void) {
        let name = playerName
        queue.async {
            let ok = ds_lan_host(name, Int32(maxPlayers)) == 0
            DispatchQueue.main.async {
                if ok {
                    self.state = .host
                    self.startPump()
                    self.publish()
                }
                self.refresh()
                done(ok)
            }
        }
    }

    /// 주소(IPv4 또는 이름)의 방에 참가 — 최대 5초
    func join(address: String, done: @escaping (Bool) -> Void) {
        let name = playerName
        stopPublishing()
        queue.async {
            let ok = ds_lan_join(name, address) == 0
            DispatchQueue.main.async {
                if ok {
                    self.state = .client
                    self.startPump()
                }
                self.refresh()
                done(ok)
            }
        }
    }

    func leave() {
        stopPublishing()
        queue.async {
            ds_lan_leave()
            DispatchQueue.main.async {
                self.state = .none
                self.stopPump()
                self.refresh()
            }
        }
    }

    // ── 연결 돌보기 ─────────────────────────

    private func startPump() {
        guard pump == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        t.setEventHandler { ds_lan_process() }
        t.resume()
        pump = t
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func stopPump() {
        pump?.cancel()
        pump = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 참가자 목록을 다시 읽고(주 스레드) 알린다. 방장이면 Bonjour 알림의 인원도 고친다
    func refresh() {
        queue.async {
            var buf = [DSLanPlayer](repeating: DSLanPlayer(), count: 16)
            let n = Int(ds_lan_players(&buf, 16))
            let maxP = Int(ds_lan_max_players())
            let st = ds_lan_state()
            DispatchQueue.main.async {
                self.players = Array(buf.prefix(n))
                self.maxPlayers = maxP
                if st == Int32(DS_LAN_NONE) && self.state != .none {
                    self.state = .none     // 방장이 방을 닫았다 등
                    self.stopPump()
                }
                if self.state == .host { self.updateTXT() }
                NotificationCenter.default.post(name: Wireless.didChange, object: self)
            }
        }
    }

    // ── Bonjour: 방 알리기(7065에 빈 UDP 리스너를 열고 이름표만 쓴다 — ENet은 7064) ──

    private func publish() {
        stopPublishing()
        do {
            let l = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: UInt16(Wireless.port + 1))!)
            l.service = NWListener.Service(name: playerName, type: "_duods._udp", txtRecord: txtRecord())
            l.newConnectionHandler = { $0.cancel() }
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    if case .failed(let e) = st { self?.bonjourProblem = "\(e)"; NSLog("DuoDS wireless: 알림 실패 \(e)") }
                    if case .waiting(let e) = st { self?.bonjourProblem = "\(e)"; NSLog("DuoDS wireless: 알림 대기 \(e)") }
                    self?.notify()
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            bonjourProblem = "\(error)"
        }
    }

    private func stopPublishing() {
        listener?.cancel()
        listener = nil
    }

    private func txtRecord() -> NWTXTRecord {
        var t = NWTXTRecord()
        t["players"] = "\(max(players.count, 1))"
        t["max"] = "\(maxPlayers)"
        t["port"] = "\(Wireless.port)"
        t["v"] = "1"
        return t
    }

    private func updateTXT() {
        guard let l = listener else { return }
        l.service = NWListener.Service(name: playerName, type: "_duods._udp", txtRecord: txtRecord())
    }

    // ── Bonjour: 방 찾기(무선 화면이 열려 있는 동안) ──

    func startBrowsing() {
        guard browser == nil else { return }
        rooms = []
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_duods._udp", domain: nil), using: .udp)
        b.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                if case .failed(let e) = st { self?.bonjourProblem = "\(e)" }
                if case .waiting(let e) = st { self?.bonjourProblem = "\(e)" }
                if case .ready = st { self?.bonjourProblem = nil }
                self?.notify()
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.update(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [Room] = []
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            if listener != nil && name == playerName { continue }   // 내 방은 빼고
            var players = 1, maxP = 0
            if case .bonjour(let txt) = r.metadata {
                players = txt["players"].flatMap { Int($0) } ?? 1
                maxP = txt["max"].flatMap { Int($0) } ?? 0
            }
            let known = rooms.first { $0.name == name }
            next.append(Room(name: name, players: players, maxPlayers: maxP, address: known?.address, endpoint: r.endpoint))
            if known?.address == nil { resolve(name, r.endpoint) }
        }
        rooms = next.sorted { $0.name < $1.name }
        notify()
    }

    /// 서비스 이름 → IPv4: 잠깐 UDP 연결을 열어 경로의 상대 주소를 읽는다
    private func resolve(_ name: String, _ endpoint: NWEndpoint) {
        guard resolving[name] == nil else { return }
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        c.stateUpdateHandler = { [weak self] st in
            guard case .ready = st else {
                if case .failed = st { DispatchQueue.main.async { self?.resolving[name] = nil } }
                return
            }
            var ip: String?
            if case .hostPort(let host, _) = c.currentPath?.remoteEndpoint, case .ipv4(let v4) = host {
                ip = v4.debugDescription
            }
            c.cancel()
            DispatchQueue.main.async {
                self?.resolving[name] = nil
                if let i = self?.rooms.firstIndex(where: { $0.name == name }) { self?.rooms[i].address = ip }
                self?.notify()
            }
        }
        resolving[name] = c
        c.start(queue: .main)
    }

    private func notify() { NotificationCenter.default.post(name: Wireless.didChange, object: self) }

    // ── 이 기기의 IP(맥 melonDS에서 직접 붙을 때 넣을 주소) ──

    var localIPv4: String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name == "en0" || (result == nil && name.hasPrefix("en")) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: host)
                if name == "en0" { break }
            }
        }
        return result
    }

    static func name(_ p: DSLanPlayer) -> String {
        withUnsafeBytes(of: p.name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func ipString(_ address: UInt32) -> String {
        // 네트워크 순서(작은 끝 메모리에서 첫 바이트가 첫 자리)
        "\(address & 0xFF).\((address >> 8) & 0xFF).\((address >> 16) & 0xFF).\(address >> 24)"
    }
}
