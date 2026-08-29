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
    private var borderConstraint: NSLayoutConstraint?

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

    var placeholderText = "向 ZCode 提问…" {
        didSet { placeholder.text = placeholderText }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 26
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        addSubview(card)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.setImage(UIImage(systemName: "plus"), for: .normal)
        attachButton.tintColor = ZUIColor.ink(UITraitCollection.current)
        attachButton.backgroundColor = ZUIColor.chip(UITraitCollection.current)
        attachButton.layer.cornerRadius = 17
        attachButton.addTarget(self, action: #selector(tapAttach), for: .touchUpInside)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 16)
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        textView.tintColor = ZUIColor.accent(UITraitCollection.current)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "向 ZCode 提问…"
        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = ZUIColor.inkFaint(UITraitCollection.current)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        sendButton.tintColor = .white
        sendButton.backgroundColor = ZUIColor.accent(UITraitCollection.current)
        sendButton.layer.cornerRadius = 17
        sendButton.addTarget(self, action: #selector(tapSend), for: .touchUpInside)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stopButton.tintColor = .white
        stopButton.backgroundColor = ZUIColor.danger
        stopButton.layer.cornerRadius = 17
        stopButton.addTarget(self, action: #selector(tapStop), for: .touchUpInside)

        card.addSubview(attachButton)
        card.addSubview(textView)
        card.addSubview(placeholder)
        card.addSubview(sendButton)
        card.addSubview(stopButton)

        textHeight = textView.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            attachButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            attachButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            attachButton.widthAnchor.constraint(equalToConstant: 34),
            attachButton.heightAnchor.constraint(equalToConstant: 34),

            sendButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            sendButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34),

            stopButton.trailingAnchor.constraint(equalTo: sendButton.trailingAnchor),
            stopButton.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
            stopButton.widthAnchor.constraint(equalTo: sendButton.widthAnchor),
            stopButton.heightAnchor.constraint(equalTo: sendButton.heightAnchor),

            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            textView.topAnchor.constraint(equalTo: card.topAnchor, constant: 5),
            textView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -5),
            textHeight!,

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholder.centerYAnchor.constraint(equalTo: attachButton.centerYAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func applyColors() {
        let trait = traitCollection
        card.backgroundColor = ZUIColor.surface(trait)
        card.layer.borderColor = ZUIColor.line(trait).cgColor
        textView.textColor = ZUIColor.ink(trait)
        attachButton.tintColor = ZUIColor.ink(trait)
        attachButton.backgroundColor = ZUIColor.chip(trait)
        sendButton.backgroundColor = ZUIColor.accent(trait)
        placeholder.textColor = ZUIColor.inkFaint(trait)
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
        applyColors()
        refreshButtons()
    }

    private func refreshButtons() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isHidden = running
        stopButton.isHidden = !running
        sendButton.alpha = hasText ? 1 : 0.4
        sendButton.isEnabled = hasText
    }

    @objc private func tapSend() { delegate?.composerDidTapSend(self) }
    @objc private func tapStop() { delegate?.composerDidTapStop(self) }
    @objc private func tapAttach() { delegate?.composerDidTapAttach(self) }
}
