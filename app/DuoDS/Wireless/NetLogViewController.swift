import UIKit

/// 접속 기록 보기(설정 › 인터넷(WFC) › 접속 기록): 코어가 Documents/Logs/wfc-log.txt에 쓰는 글을 끝부분부터 보여 준다.
/// 1초마다 파일이 자랐는지 보고 다시 읽는다(맨 아래를 보고 있었으면 계속 맨 아래). 복사 · 지우기는 알림창 없이 버튼 글자로 확인.
final class NetLogViewController: UIViewController {
    private let textView = UITextView()
    private let url = Library.shared.wfcLogURL
    private var timer: Timer?
    private var lastSize: UInt64 = .max
    private var confirmClear = false
    private lazy var copyItem = UIBarButtonItem(title: "복사", primaryAction: UIAction { [weak self] _ in self?.copyAll() })
    private lazy var clearItem = UIBarButtonItem(title: "지우기", primaryAction: UIAction { [weak self] _ in self?.clear() })
    /// 너무 길면 끝부분만(텍스트 뷰가 무거워지지 않게)
    private let tailBytes = 200 * 1024

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "접속 기록"
        view.backgroundColor = .systemBackground
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 16, right: 8)
        textView.alwaysBounceVertical = true
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(textView)
        navigationItem.rightBarButtonItems = [clearItem, copyItem]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload(force: false) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    private func reload(force: Bool) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard force || size != lastSize else { return }
        lastSize = size
        let atBottom = textView.contentOffset.y >= textView.contentSize.height - textView.bounds.height - 40
        var text = ""
        if let h = try? FileHandle(forReadingFrom: url) {
            if size > UInt64(tailBytes) { try? h.seek(toOffset: size - UInt64(tailBytes)) }
            let data = (try? h.readToEnd()) ?? Data()
            try? h.close()
            text = String(decoding: data, as: UTF8.self)
            if size > UInt64(tailBytes), let nl = text.firstIndex(of: "\n") { text = "…(앞부분 줄임)\n" + text[text.index(after: nl)...] }
        }
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        textView.text = empty ? "아직 기록이 없습니다.\n게임에서 온라인에 접속하면 여기에 남습니다." : text
        textView.textColor = empty ? .secondaryLabel : .label
        copyItem.isEnabled = !empty
        if force || atBottom {
            textView.layoutIfNeeded()
            let y = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = textView.text
        copyItem.title = "복사됨"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyItem.title = "복사" }
    }

    private func clear() {
        guard confirmClear else {
            confirmClear = true
            clearItem.title = "정말 지우기"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.confirmClear = false
                self?.clearItem.title = "지우기"
            }
            return
        }
        confirmClear = false
        clearItem.title = "지우기"
        ds_net_clear_log()
        reload(force: true)
    }
}
