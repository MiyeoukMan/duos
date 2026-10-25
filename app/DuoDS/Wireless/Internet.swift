import Foundation

/// DS 인터넷(Nintendo WFC 대체 서버) — 고른 서버를 코어에 알리고(ds_net_set_server), 게임이 실제로 주고받는지 지켜본다(무선 LED).
/// 게임의 DNS 질의는 코어가 모두 이 서버로 넘긴다 → 게임 안 Nintendo WFC 설정은 처음 그대로(접속점 melonAP · DNS 자동) 두면 된다.
final class Internet {
    static let shared = Internet()
    static let didChange = Notification.Name("DuoDSInternetDidChange")

    enum Server: String, CaseIterable {
        case off, wiimmfi, kaeru, custom

        var title: String {
            switch self {
            case .off: return "끄기"
            case .wiimmfi: return "Wiimmfi"
            case .kaeru: return "Kaeru WFC"
            case .custom: return "직접 입력"
            }
        }

        /// 프리셋 DNS — 2026-10-25에 그 DNS에 nas.nintendowifi.net을 물어 각 서버의 주소가 나오는 것을 확인했다
        var presetDNS: String? {
            switch self {
            case .wiimmfi: return "95.217.77.151"
            case .kaeru: return "178.62.43.212"
            default: return nil
            }
        }
    }

    private(set) var status = DSNetStatus()
    /// 최근 3초 안에 게임이 인터넷과 주고받았다(무선 LED)
    private(set) var active = false
    /// 직접 입력한 주소가 틀려 꺼 둔 상태
    private(set) var invalidCustom = false
    private var timer: Timer?
    private var lastBytes: UInt64 = 0
    private var lastActivity = Date.distantPast

    /// 지금 고른 서버의 DNS — 끄기 · 빈 직접 입력이면 nil
    var dns: String? {
        let s = Settings.shared
        if s.wfcServer == .custom {
            let t = s.wfcCustomDNS.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return s.wfcServer.presetDNS
    }

    /// 설정을 코어에 알린다 — 앱을 켤 때 · 서버를 바꿀 때
    func apply() {
        var ok = true
        if let dns {
            ok = dns.withCString { ds_net_set_server($0) } == 0
            if !ok { ds_net_set_server(nil) }
        } else {
            ds_net_set_server(nil)
        }
        invalidCustom = !ok
        if dns != nil && ok { startWatching() } else { stopWatching() }
        refresh(force: true)
    }

    // ── 지켜보기(1초마다 — 숫자가 바뀔 때만 알린다) ──

    private func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh(force: Bool = false) {
        var st = DSNetStatus()
        ds_net_status(&st)
        let bytes = st.bytes_in + st.bytes_out
        if bytes != lastBytes {
            lastBytes = bytes
            lastActivity = Date()
        }
        let nowActive = st.enabled != 0 && Date().timeIntervalSince(lastActivity) < 3
        let changed = force || nowActive != active || bytes != status.bytes_in + status.bytes_out
            || st.dns_queries != status.dns_queries || st.dns_failures != status.dns_failures
        status = st
        active = nowActive
        if changed { NotificationCenter.default.post(name: Internet.didChange, object: self) }
    }

    // ── 연결 시험: 서버 DNS에 nas.nintendowifi.net을 물어본다 ──

    func probe(done: @escaping (_ address: String?, _ ms: Int) -> Void) {
        guard let dns else { done(nil, 0); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            var out = [CChar](repeating: 0, count: 64)
            let r = ds_net_probe(dns, "nas.nintendowifi.net", &out, Int32(out.count), 3000)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let address = r == 0 ? String(cString: out) : nil
            DispatchQueue.main.async { done(address, ms) }
        }
    }

    // ── 보여 줄 글 ──

    var lastName: String {
        withUnsafeBytes(of: status.last_name) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func ipString(_ address: UInt32) -> String {
        "\(address & 0xFF).\((address >> 8) & 0xFF).\((address >> 16) & 0xFF).\(address >> 24)"
    }

    static func bytesString(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}
