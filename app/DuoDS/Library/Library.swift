import UIKit

/// 게임 하나(.nds 파일)와 그 세이브 · 상태 저장 자리.
struct RomEntry: Hashable {
    let url: URL
    let title: String
    let publisher: String
    let gameCode: String

    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var saveURL: URL { Library.shared.savesDir.appendingPathComponent(baseName + ".sav") }
    var stateURL: URL { Library.shared.statesDir.appendingPathComponent(baseName + ".mst") }
    var hasState: Bool { FileManager.default.fileExists(atPath: stateURL.path) }

    static func == (a: RomEntry, b: RomEntry) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

/// ROM은 문서 폴더(파일 앱 · Finder로 보인다)의 맨 위나 ROMs 폴더에 둔다. 세이브는 Saves, 상태 저장은 States.
final class Library {
    static let shared = Library()

    let documentsDir: URL
    let romsDir: URL
    let savesDir: URL
    let statesDir: URL
    let supportDir: URL
    /// 접속 기록(인터넷 — 원인 찾기). 문서 폴더라 맥 Finder(파일 공유)로도 꺼낼 수 있다
    let logsDir: URL
    var wfcLogURL: URL { logsDir.appendingPathComponent("wfc-log.txt") }

    private var iconCache: [URL: UIImage] = [:]

    private init() {
        let fm = FileManager.default
        documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        romsDir = documentsDir.appendingPathComponent("ROMs", isDirectory: true)
        savesDir = documentsDir.appendingPathComponent("Saves", isDirectory: true)
        statesDir = documentsDir.appendingPathComponent("States", isDirectory: true)
        supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("melonDS", isDirectory: true)
        logsDir = documentsDir.appendingPathComponent("Logs", isDirectory: true)
        for d in [romsDir, savesDir, statesDir, supportDir, logsDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// 처음 켤 때 데모 카트리지(직접 만든 시험 프로그램 — 앱 묶음의 duos-demo.nds)를 ROMs에 한 번 넣어 둔다.
    /// 롬이 없는 사람(앱 심사 포함)도 바로 꽂아 볼 수 있게. 지우면 다시 넣지 않는다
    func seedDemoOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "demoSeeded"), let src = Bundle.main.url(forResource: "duos-demo", withExtension: "nds") else { return }
        let dst = romsDir.appendingPathComponent("DuoS Demo.nds")
        if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: src, to: dst) }
        d.set(true, forKey: "demoSeeded")
    }

    func scan() -> [RomEntry] {
        let fm = FileManager.default
        var urls: [URL] = []
        for dir in [documentsDir, romsDir] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            urls += items.filter { $0.pathExtension.lowercased() == "nds" }
        }
        return urls.compactMap { RomInfo.read($0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 바깥(파일 앱 · 공유)에서 받은 ROM을 ROMs 폴더로 복사한다. 이미 문서 폴더 안이면 그대로 쓴다.
    func importROM(from url: URL) throws -> RomEntry {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var dest = url
        if !url.standardizedFileURL.path.hasPrefix(documentsDir.standardizedFileURL.path) {
            dest = romsDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
        }
        guard let entry = RomInfo.read(dest) else {
            throw EmulatorError.load("DS ROM이 아닌 파일입니다: \(url.lastPathComponent)")
        }
        return entry
    }

    func delete(_ rom: RomEntry) throws {
        try FileManager.default.removeItem(at: rom.url)
        iconCache[rom.url] = nil
    }

    func icon(for rom: RomEntry) -> UIImage? {
        if let i = iconCache[rom.url] { return i }
        let i = RomInfo.icon(rom.url)
        iconCache[rom.url] = i
        return i
    }
}

/// NDS 헤더 · 배너에서 이름 · 아이콘을 읽는다.
enum RomInfo {
    static func read(_ url: URL) -> RomEntry? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 0x200), header.count == 0x200 else { return nil }
        let arm9Offset = header.u32(0x20)
        guard arm9Offset >= 0x200 else { return nil }
        let code = String(bytes: header[0x0C..<0x10], encoding: .ascii) ?? ""
        let internalName = String(bytes: header[0..<12].prefix { $0 != 0 }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""

        var title = ""
        var publisher = ""
        let bannerOffset = UInt64(header.u32(0x68))
        if bannerOffset != 0, (try? fh.seek(toOffset: bannerOffset)) != nil, let banner = try? fh.read(upToCount: 0xA40), banner.count >= 0x840 {
            let version = banner.u16(0)
            // 한국어(배너 3판 이상) → 영어 → 일본어
            var candidates = [0x340, 0x240]
            if version >= 3 && banner.count >= 0xA40 { candidates.insert(0x940, at: 0) }
            for off in candidates {
                let lines = banner.utf16String(off, 0x100).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !lines.isEmpty else { continue }
                if lines.count >= 3 {
                    title = lines.dropLast().joined(separator: " ")
                    publisher = lines.last!
                } else if lines.count == 2 {
                    title = lines[0]
                    publisher = lines[1]
                } else {
                    title = lines[0]
                }
                break
            }
        }
        if title.isEmpty { title = internalName.isEmpty ? url.deletingPathExtension().lastPathComponent : internalName }
        return RomEntry(url: url, title: title, publisher: publisher, gameCode: code)
    }

    /// 32 × 32, 4비트 타일(8 × 8 칸 16개) + 16색 팔레트. 0번 색은 투명.
    static func icon(_ url: URL) -> UIImage? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let header = try? fh.read(upToCount: 0x200), header.count == 0x200 else { return nil }
        let bannerOffset = UInt64(header.u32(0x68))
        guard bannerOffset != 0, (try? fh.seek(toOffset: bannerOffset)) != nil,
              let banner = try? fh.read(upToCount: 0x240), banner.count == 0x240 else { return nil }
        var palette = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let c = banner.u16(0x220 + i * 2)
            let r = UInt32(c & 31) * 255 / 31, g = UInt32((c >> 5) & 31) * 255 / 31, b = UInt32((c >> 10) & 31) * 255 / 31
            palette[i] = i == 0 ? 0 : (0xFF << 24) | (b << 16) | (g << 8) | r   // RGBA 메모리 순서(작은 끝)
        }
        var pixels = [UInt32](repeating: 0, count: 32 * 32)
        for tile in 0..<16 {
            let tx = (tile % 4) * 8, ty = (tile / 4) * 8
            for i in 0..<32 {
                let byte = banner[banner.startIndex + 0x20 + tile * 32 + i]
                let x = tx + (i % 4) * 2, y = ty + i / 4
                pixels[y * 32 + x] = palette[Int(byte & 0xF)]
                pixels[y * 32 + x + 1] = palette[Int(byte >> 4)]
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension Data {
    func u16(_ at: Int) -> UInt16 { UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    func utf16String(_ at: Int, _ bytes: Int) -> String {
        var units: [UInt16] = []
        var i = at
        while i + 1 < at + bytes && i + 1 < count {
            let u = u16(i)
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
