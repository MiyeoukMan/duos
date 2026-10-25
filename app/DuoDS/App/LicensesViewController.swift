import UIKit

/// 정보 › 오픈 소스 라이선스: 앱에 들어간 오픈 소스와 라이선스 전문(Licenses/*.txt — 원본 폴더의 라이선스 파일을 그대로 옮긴 것).
/// DuoS 자체도 melonDS를 바탕으로 해 GPL-3.0을 따른다.
final class LicensesViewController: UITableViewController {
    struct Entry {
        let name: String
        let detail: String
        let file: String
    }

    static let entries: [Entry] = [
        Entry(name: "DuoS", detail: "GPL-3.0 — melonDS를 바탕으로 한 앱", file: "license-gpl-3.0"),
        Entry(name: "melonDS", detail: "GPL-3.0 · Copyright 2016-2026 melonDS team", file: "license-gpl-3.0"),
        Entry(name: "teakra", detail: "MIT · Copyright (c) 2018 Weiyi Wang", file: "license-teakra"),
        Entry(name: "ENet", detail: "MIT · Copyright (c) 2002-2024 Lee Salzman", file: "license-enet"),
        Entry(name: "libslirp", detail: "BSD-3-Clause 등 · Danny Gasparovski 외", file: "license-libslirp"),
        Entry(name: "Blip_Buffer (blip_buf)", detail: "LGPL-2.1", file: "license-blip-buf"),
        Entry(name: "FatFs", detail: "BSD 1조항 계열 · ChaN", file: "license-fatfs"),
        Entry(name: "xxHash", detail: "BSD-2-Clause · Yann Collet", file: "license-xxhash"),
        Entry(name: "tiny-AES-c", detail: "Unlicense(공개 영역)", file: "license-tiny-aes-c"),
        Entry(name: "SHA-1 in C", detail: "공개 영역 · Steve Reid", file: "license-sha1"),
    ]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "오픈 소스 라이선스"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Self.entries.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "DuoS는 GPL-3.0에 따라 배포됩니다. 게임 롬 · 닌텐도 바이오스 · 펌웨어는 들어 있지 않습니다."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        let e = Self.entries[indexPath.row]
        c.text = e.name
        c.secondaryText = e.detail
        c.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = c
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let e = Self.entries[indexPath.row]
        navigationController?.pushViewController(LicenseTextViewController(title: e.name, file: e.file), animated: true)
    }
}

/// 라이선스 전문 한 장
final class LicenseTextViewController: UIViewController {
    private let file: String

    init(title: String, file: String) {
        self.file = file
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let tv = UITextView(frame: view.bounds)
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 20, right: 10)
        let url = Bundle.main.url(forResource: file, withExtension: "txt")
        tv.text = url.flatMap { (try? String(contentsOf: $0, encoding: .utf8)) ?? (try? String(contentsOf: $0, encoding: .isoLatin1)) }
            ?? "(라이선스 파일을 찾을 수 없습니다: \(file).txt)"
        view.addSubview(tv)
    }
}
