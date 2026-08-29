import UIKit

protocol ComposerViewDelegate: AnyObject {
    func composerDidChangeHeight(_ composer: ComposerView)
    func composerDidTapSend(_ composer: ComposerView)
    func composerDidTapStop(_ composer: ComposerView)
    func composerDidTapAttach(_ composer: ComposerView)
}

final class ComposerView: UIView, UITextViewDelegate {
    weak var delegate: ComposerViewDelegate?

    let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private let card = UIView()
    private var textHeight: NSLayoutConstraint?

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            refresh()
        }
    }

    var running = false {
        didSet { refreshButtons() }
    }

    var connected = false {
        didSet { refresh() }
    }

    var placeholderText = "连接后向 ZCode 提问…" {
        didSet { placeholder.text = placeholderText }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = ZUIColor.creamCard(traitCollection)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.08
        card.layer.shadowRadius = 16
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        addSubview(card)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.setImage(UIImage(systemName: "plus"), for: .normal)
        attachButton.tintColor = ZUIColor.ink
        attachButton.backgroundColor = UIColor.white.withAlphaComponent(0.55)
        attachButton.layer.cornerRadius = 18
        attachButton.addTarget(self, action: #selector(tapAttach), for: .touchUpInside)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 16.5, weight: .regular)
        textView.textColor = ZUIColor.ink
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        textView.tintColor = ZUIColor.accent

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "连接后向 ZCode 提问…"
        placeholder.font = .systemFont(ofSize: 16.5)
        placeholder.textColor = ZUIColor.ink.withAlphaComponent(0.35)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        sendButton.tintColor = .white
        sendButton.backgroundColor = ZUIColor.accent
        sendButton.layer.cornerRadius = 18
        sendButton.addTarget(self, action: #selector(tapSend), for: .touchUpInside)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stopButton.tintColor = .white
        stopButton.backgroundColor = ZUIColor.accentDeep
        stopButton.layer.cornerRadius = 18
        stopButton.addTarget(self, action: #selector(tapStop), for: .touchUpInside)

        card.addSubview(attachButton)
        card.addSubview(textView)
        card.addSubview(placeholder)
        card.addSubview(sendButton)
        card.addSubview(stopButton)

        textHeight = textView.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            attachButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            attachButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            attachButton.widthAnchor.constraint(equalToConstant: 36),
            attachButton.heightAnchor.constraint(equalToConstant: 36),

            sendButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            sendButton.widthAnchor.constraint(equalToConstant: 36),
            sendButton.heightAnchor.constraint(equalToConstant: 36),

            stopButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            stopButton.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
            stopButton.widthAnchor.constraint(equalTo: sendButton.widthAnchor),
            stopButton.heightAnchor.constraint(equalTo: sendButton.heightAnchor),

            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 6),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            textView.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            textView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            textHeight!,

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholder.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        card.backgroundColor = ZUIColor.creamCard(traitCollection)
        textView.textColor = ZUIColor.ink(traitCollection)
        attachButton.tintColor = ZUIColor.ink(traitCollection)
    }

    func textViewDidChange(_ textView: UITextView) {
        refresh()
        delegate?.composerDidChangeHeight(self)
    }

    private func refresh() {
        placeholder.isHidden = !(textView.text ?? "").isEmpty
        let size = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: 180))
        textHeight?.constant = min(max(40, size.height), 160)
        textView.isScrollEnabled = size.height > 160
        refreshButtons()
    }

    private func refreshButtons() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = running
        stopButton.isHidden = !running
        sendButton.alpha = (hasText && connected) ? 1 : 0.45
        sendButton.isEnabled = hasText && connected
        textView.isEditable = connected
    }

    @objc private func tapSend() { delegate?.composerDidTapSend(self) }
    @objc private func tapStop() { delegate?.composerDidTapStop(self) }
    @objc private func tapAttach() { delegate?.composerDidTapAttach(self) }
}
