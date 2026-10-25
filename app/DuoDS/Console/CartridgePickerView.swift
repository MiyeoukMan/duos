import UIKit

/// 카트리지 고르기: 접은 뒷면 위에 어둡게 깔리고, 카드가 가로로 늘어선다(옆으로 넘김).
/// 카드를 누르면 `onPick(rom, 이 뷰 좌표의 카드 자리)`, "가져오기" 카드는 `onImport`, 길게 누르면 지우기.
final class CartridgePickerView: UIView, UIContextMenuInteractionDelegate {
    var onPick: ((RomEntry, CGRect) -> Void)?
    var onImport: (() -> Void)?
    var onDelete: ((RomEntry) -> Void)?
    var onClose: (() -> Void)?
    /// 길게 눌러 뜬 메뉴가 닫힐 때(시스템이 방향 잠금을 풀었을 수 있다)
    var onMenuClosed: (() -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let scroll = UIScrollView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var cards: [CartridgeView] = []
    private var roms: [RomEntry] = []
    private(set) var current: RomEntry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(blur)
        blur.contentView.backgroundColor = UIColor(white: 0, alpha: 0.25)
        blur.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.decelerationRate = .fast
        addSubview(scroll)
        titleLabel.text = "카트리지"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        addSubview(titleLabel)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)), for: .normal)
        closeButton.tintColor = UIColor(white: 1, alpha: 0.8)
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func close() { onClose?() }

    /// 카드 목록을 다시 채운다. `current`(꽂혀 있던 카드)를 가운데로.
    func reload(_ roms: [RomEntry], current: RomEntry?) {
        self.roms = roms
        self.current = current
        cards.forEach { $0.removeFromSuperview() }
        cards = (roms.map { Optional($0) } + [nil]).map { rom in
            let c = CartridgeView(rom: rom)
            c.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            if rom != nil { c.addInteraction(UIContextMenuInteraction(delegate: self)) }
            scroll.addSubview(c)
            return c
        }
        setNeedsLayout()
        layoutIfNeeded()
        if let cur = current, let i = roms.firstIndex(of: cur) { center(on: i, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        let safe = safeAreaInsets
        titleLabel.frame = CGRect(x: safe.left + 24, y: max(safe.top, 12) + 8, width: 300, height: 30)
        closeButton.frame = CGRect(x: bounds.maxX - safe.right - 56, y: max(safe.top, 12) + 2, width: 44, height: 44)
        let h = min(bounds.height * 0.56, 300)
        let w = h * CartridgeView.aspect
        let gap: CGFloat = 28
        scroll.frame = CGRect(x: 0, y: titleLabel.frame.maxY + 10, width: bounds.width, height: bounds.height - titleLabel.frame.maxY - 10 - max(safe.bottom, 12))
        let side = max(safe.left + 24, (bounds.width - w) / 2 - w - gap)
        for (i, c) in cards.enumerated() {
            c.frame = CGRect(x: side + CGFloat(i) * (w + gap), y: (scroll.bounds.height - h) / 2, width: w, height: h)
        }
        scroll.contentSize = CGSize(width: side * 2 + CGFloat(cards.count) * (w + gap) - gap, height: scroll.bounds.height)
    }

    private func center(on i: Int, animated: Bool) {
        guard i < cards.count else { return }
        let x = cards[i].frame.midX - scroll.bounds.width / 2
        scroll.setContentOffset(CGPoint(x: min(max(0, x), max(0, scroll.contentSize.width - scroll.bounds.width)), y: 0), animated: animated)
    }

    /// 들어올 때: 카드가 아래에서 차례로 떠오른다
    func animateIn() {
        alpha = 0
        for (i, c) in cards.enumerated() { c.transform = CGAffineTransform(translationX: 0, y: 60 + CGFloat(i) * 8); c.alpha = 0 }
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        for (i, c) in cards.enumerated() {
            UIView.animate(withDuration: 0.45, delay: 0.03 * Double(i), usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
                c.transform = .identity
                c.alpha = 1
            }
        }
    }

    /// 고른 카드는 남기고 나머지만 사라진다
    func animateOut(keeping kept: CartridgeView?, completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.22) {
            self.blur.alpha = 0
            self.titleLabel.alpha = 0
            self.closeButton.alpha = 0
            for c in self.cards where c !== kept { c.alpha = 0; c.transform = CGAffineTransform(translationX: 0, y: 40) }
        } completion: { _ in completion() }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let card = g.view as? CartridgeView else { return }
        if Settings.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        UIView.animate(withDuration: 0.08, animations: { card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }) { _ in
            UIView.animate(withDuration: 0.1) { card.transform = .identity }
            if let rom = card.rom {
                self.onPick?(rom, card.convert(card.bounds, to: self))
            } else {
                self.onImport?()
            }
        }
    }

    func card(for rom: RomEntry) -> CartridgeView? { cards.first { $0.rom == rom } }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let rom = (interaction.view as? CartridgeView)?.rom else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: rom.title, children: [
                UIAction(title: "지우기", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.onDelete?(rom) },
            ])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: UIContextMenuInteractionAnimating?) {
        if let animator { animator.addCompletion { [weak self] in self?.onMenuClosed?() } } else { onMenuClosed?() }
    }
}
