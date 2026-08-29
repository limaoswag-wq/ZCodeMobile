import UIKit

final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, ComposerViewDelegate {
    var client: BridgeClient!
    var onOpenSettings: (() -> Void)?
    var onOpenTasks: (() -> Void)?
    var onScan: (() -> Void)?
    var onPaste: (() -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    private let composer = ComposerView()
    private let header = ChatHeaderView()
    private let empty = ConnectEmptyView()
    private var composerBottom: NSLayoutConstraint?
    private var messages: [ChatMessage] = []
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ZUIColor.canvas(traitCollection)
        navigationController?.setNavigationBarHidden(true, animated: false)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onSettings = { [weak self] in self?.onOpenSettings?() }
        header.onTasks = { [weak self] in self?.onOpenTasks?() }
        header.onNew = { [weak self] in
            Task { await self?.client.newTask() }
        }

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .interactive
        table.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 88
        table.register(BubbleCell.self, forCellReuseIdentifier: BubbleCell.id)
        table.register(ToolCell.self, forCellReuseIdentifier: ToolCell.id)
        table.register(WebCell.self, forCellReuseIdentifier: WebCell.id)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self

        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.onScan = { [weak self] in self?.onScan?() }
        empty.onAlbum = { [weak self] in self?.onScan?() }
        empty.onPaste = { [weak self] in self?.onPaste?() }

        view.addSubview(header)
        view.addSubview(table)
        view.addSubview(empty)
        view.addSubview(composer)

        composerBottom = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 64),

            table.topAnchor.constraint(equalTo: header.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: composer.topAnchor),

            empty.topAnchor.constraint(equalTo: table.topAnchor),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: table.bottomAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBottom!
        ])

        observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleKeyboard(note)
        }
        reloadFromClient()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reloadFromClient() {
        let next = client.snapshot.messages.filter { message in
            if message.role != "user" && message.role != "assistant" { return false }
            return !message.blocks.isEmpty
        }
        let changed = next.map(\.id) != messages.map(\.id) || next.last?.markdown != messages.last?.markdown
        messages = next
        header.configure(
            task: client.currentTask,
            connection: client.connection,
            running: client.snapshot.running,
            deviceName: client.deviceTitle
        )
        composer.running = client.snapshot.running
        composer.connected = client.connection.isConnected
        composer.placeholderText = client.connection.isConnected ? "问 ZCode…" : "连接后向 ZCode 提问…"
        empty.isHidden = client.connection.isConnected
        empty.configure(connection: client.connection, error: client.errorText)
        if composer.textView.isFirstResponder == false {
            composer.text = client.composerText
        }
        if changed {
            table.reloadData()
            scrollToBottom(animated: false)
        }
        view.backgroundColor = ZUIColor.canvas(traitCollection)
    }

    func numberOfSections(in tableView: UITableView) -> Int { messages.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleBlocks(in: messages[section]).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = messages[indexPath.section]
        let block = visibleBlocks(in: message)[indexPath.row]
        if block.kind == "tool" {
            let cell = tableView.dequeueReusableCell(withIdentifier: ToolCell.id, for: indexPath) as! ToolCell
            cell.configure(block, trait: traitCollection)
            return cell
        }
        if block.kind == "mermaid" || (block.kind == "code" && block.text.count > 280) {
            let cell = tableView.dequeueReusableCell(withIdentifier: WebCell.id, for: indexPath) as! WebCell
            cell.onHeightChange = { [weak tableView] in
                tableView?.beginUpdates()
                tableView?.endUpdates()
            }
            cell.configure(code: block.text, language: block.kind == "mermaid" ? "mermaid" : "code", trait: traitCollection)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: BubbleCell.id, for: indexPath) as! BubbleCell
        cell.configure(block: block, user: message.isUser, trait: traitCollection)
        return cell
    }

    func composerDidChangeHeight(_ composer: ComposerView) {
        view.layoutIfNeeded()
        scrollToBottom(animated: false)
    }

    func composerDidTapSend(_ composer: ComposerView) {
        client.composerText = composer.text
        Task { await client.sendCurrent() }
        composer.text = ""
    }

    func composerDidTapStop(_ composer: ComposerView) {
        Task { await client.stopTask() }
    }

    func composerDidTapAttach(_ composer: ComposerView) {
        onOpenTasks?()
    }

    private func visibleBlocks(in message: ChatMessage) -> [ChatBlock] {
        var result: [ChatBlock] = []
        for block in message.blocks {
            if block.kind == "reasoning" {
                if client.settings.showReasoning && !block.text.isEmpty { result.append(block) }
                continue
            }
            if block.kind == "tool" {
                result.append(block)
                continue
            }
            if block.kind != "text" {
                if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(block)
                }
                continue
            }
            let segments = MarkdownRenderer.segments(from: block.text)
            var textChunks: [String] = []
            func flushText(_ index: Int) {
                let joined = textChunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    result.append(ChatBlock(id: "\(block.id)-text-\(index)", kind: "text", text: joined))
                }
                textChunks.removeAll()
            }
            for (index, segment) in segments.enumerated() {
                switch segment.kind {
                case .code:
                    flushText(index)
                    result.append(ChatBlock(id: "\(block.id)-code-\(index)", kind: "code", text: segment.text))
                case .mermaid:
                    flushText(index)
                    result.append(ChatBlock(id: "\(block.id)-mermaid-\(index)", kind: "mermaid", text: segment.text))
                case .heading:
                    textChunks.append("# " + segment.text)
                case .bullet:
                    textChunks.append("- " + segment.text)
                case .quote:
                    textChunks.append("> " + segment.text)
                case .divider:
                    textChunks.append("---")
                case .paragraph:
                    textChunks.append(segment.text)
                }
            }
            flushText(segments.count)
        }
        return result
    }

    private func scrollToBottom(animated: Bool) {
        let sections = table.numberOfSections
        guard sections > 0 else { return }
        let rows = table.numberOfRows(inSection: sections - 1)
        guard rows > 0 else { return }
        table.scrollToRow(at: IndexPath(row: rows - 1, section: sections - 1), at: .bottom, animated: animated)
    }

    private func handleKeyboard(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        let overlap = max(0, view.safeAreaLayoutGuide.layoutFrame.maxY - local.minY)
        composerBottom?.constant = -overlap
        UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
    }
}

final class ChatHeaderView: UIView {
    var onSettings: (() -> Void)?
    var onTasks: (() -> Void)?
    var onNew: (() -> Void)?

    private let title = UILabel()
    private let subtitle = UILabel()
    private let settings = UIButton(type: .system)
    private let tasks = UIButton(type: .system)
    private let add = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12, weight: .medium)
        subtitle.textColor = ZUIColor.ink.withAlphaComponent(0.55)
        [title, subtitle].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        func round(_ button: UIButton, image: String) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(UIImage(systemName: image), for: .normal)
            button.tintColor = ZUIColor.ink
            button.backgroundColor = UIColor.white.withAlphaComponent(0.62)
            button.layer.cornerRadius = 18
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        round(settings, image: "gearshape")
        round(tasks, image: "square.stack")
        round(add, image: "plus")
        settings.addTarget(self, action: #selector(tapSettings), for: .touchUpInside)
        tasks.addTarget(self, action: #selector(tapTasks), for: .touchUpInside)
        add.addTarget(self, action: #selector(tapNew), for: .touchUpInside)

        let labels = UIStackView(arrangedSubviews: [title, subtitle])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let right = UIStackView(arrangedSubviews: [add, tasks, settings])
        right.axis = .horizontal
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labels)
        addSubview(right)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(task: TaskSummary?, connection: ConnectionState, running: Bool, deviceName: String) {
        if connection.isConnected {
            title.text = task?.title.isEmpty == false ? task!.title : deviceName
            let status = running ? "进行中" : (task?.statusLabel ?? "已连接")
            subtitle.text = "\(deviceName) · \(status)"
        } else {
            title.text = "ZCode Mobile"
            subtitle.text = connection.label
        }
    }

    @objc private func tapSettings() { onSettings?() }
    @objc private func tapTasks() { onTasks?() }
    @objc private func tapNew() { onNew?() }
}

final class ConnectEmptyView: UIView {
    var onScan: (() -> Void)?
    var onAlbum: (() -> Void)?
    var onPaste: (() -> Void)?

    private let title = UILabel()
    private let subtitle = UILabel()
    private let scan = UIButton(type: .system)
    private let album = UIButton(type: .system)
    private let paste = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "连接电脑上的 ZCode"
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = ZUIColor.ink
        title.textAlignment = .center

        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = "扫描桌面端「移动端远程控制」二维码，或粘贴复制出来的地址。"
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = ZUIColor.ink.withAlphaComponent(0.55)
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        func pill(_ button: UIButton, title: String, filled: Bool) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            button.layer.cornerRadius = 22
            button.layer.cornerCurve = .continuous
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            if filled {
                button.backgroundColor = ZUIColor.accent
                button.setTitleColor(.white, for: .normal)
            } else {
                button.backgroundColor = UIColor.white.withAlphaComponent(0.72)
                button.setTitleColor(ZUIColor.ink, for: .normal)
            }
        }
        pill(scan, title: "扫描二维码连接", filled: true)
        pill(album, title: "相册导入", filled: false)
        pill(paste, title: "粘贴远控地址", filled: false)
        scan.addTarget(self, action: #selector(tapScan), for: .touchUpInside)
        album.addTarget(self, action: #selector(tapAlbum), for: .touchUpInside)
        paste.addTarget(self, action: #selector(tapPaste), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, scan, album, paste])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(18, after: subtitle)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(connection: ConnectionState, error: String?) {
        switch connection {
        case .connecting:
            subtitle.text = "正在连接桌面端…"
        case .waiting:
            subtitle.text = "已扫码，正在等待电脑上的 ZCode 配对。保持桌面端远控页面开着。"
        case .offline(let message):
            subtitle.text = error ?? message
        default:
            subtitle.text = error ?? "扫描桌面端「移动端远程控制」二维码，或粘贴复制出来的地址。"
        }
    }

    @objc private func tapScan() { onScan?() }
    @objc private func tapAlbum() { onAlbum?() }
    @objc private func tapPaste() { onPaste?() }
}

final class BubbleCell: UITableViewCell {
    static let id = "bubble"
    private let bubble = UIView()
    private let label = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 20
        bubble.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isScrollEnabled = false
        label.backgroundColor = .clear
        label.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        label.textContainer.lineFragmentPadding = 0
        contentView.addSubview(bubble)
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14)
        ])
        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        maxWidth = bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.84)
        leading.isActive = true
        trailing.isActive = true
        maxWidth.isActive = true
    }

    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var maxWidth: NSLayoutConstraint!

    required init?(coder: NSCoder) { nil }

    func configure(block: ChatBlock, user: Bool, trait: UITraitCollection) {
        label.attributedText = MarkdownRenderer.attributed(from: block.text, trait: trait, user: user)
        bubble.backgroundColor = user ? ZUIColor.userBubble : ZUIColor.assistantBubble(trait)
        leading.isActive = !user
        trailing.isActive = user
        bubble.layer.maskedCorners = user
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
    }
}

final class ToolCell: UITableViewCell {
    static let id = "tool"
    private let chip = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.font = .systemFont(ofSize: 13, weight: .semibold)
        chip.textAlignment = .center
        chip.layer.cornerRadius = 14
        chip.layer.cornerCurve = .continuous
        chip.clipsToBounds = true
        contentView.addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            chip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            chip.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            chip.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ block: ChatBlock, trait: UITraitCollection) {
        let name = block.tool ?? "工具"
        let status = block.status == "running" ? "进行中" : "完成"
        chip.text = "  \(name) · \(status)  "
        chip.textColor = ZUIColor.ink(trait)
        chip.backgroundColor = ZUIColor.creamCard(trait)
    }
}
