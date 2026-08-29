import UIKit

/// 聊天页（UIKit 表格）：用户气泡 / 已工作折叠时间线 / 正文文档流。
/// 首页（无活动任务）也复用这个控制器：头部为 ☰，中间是 Logo + 问候。
final class ChatViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, ComposerViewDelegate {
    var app: AppState!
    var onOpenSidebar: (() -> Void)?
    var onBack: (() -> Void)?
    var onOpenModelMenu: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onOpenAttach: (() -> Void)?
    var onOpenTasks: (() -> Void)?
    var onReviewFile: ((FileChangeInfo) -> Void)?
    var onOpenFile: ((FileChangeInfo) -> Void)?

    private let table = UITableView(frame: .zero, style: .plain)
    private let composer = ComposerView()
    private let header = ChatHeader()
    private let emptyView = ChatEmptyView()
    private var composerBottom: NSLayoutConstraint?
    private var rows: [ChatRow] = []
    private var observer: NSObjectProtocol?
    private var runningTimer: Timer?
    private var expandedWorks: Set<String> = []
    private var expandedItems: Set<String> = []
    private var lastSignature = ""

    enum ChatRow {
        case user(id: String, text: String, time: Int)
        case work(id: String, items: [WorkItem], startMs: Int, endMs: Int, running: Bool)
        case text(id: String, markdown: String)
        case web(id: String, code: String, language: String)
        case files([FileChangeInfo])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ZUIColor.canvas(traitCollection)
        navigationController?.setNavigationBarHidden(true, animated: false)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onMenu = { [weak self] in self?.onOpenSidebar?() }
        header.onBack = { [weak self] in self?.onBack?() }
        header.onPill = { [weak self] in self?.onOpenModelMenu?() }
        header.onNew = { [weak self] in self?.onNewChat?() }

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .interactive
        table.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 10, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 80
        table.register(UserCell.self, forCellReuseIdentifier: UserCell.id)
        table.register(WorkCell.self, forCellReuseIdentifier: WorkCell.id)
        table.register(BodyCell.self, forCellReuseIdentifier: BodyCell.id)
        table.register(WebCell.self, forCellReuseIdentifier: WebCell.id)
        table.register(FileCardCell.self, forCellReuseIdentifier: FileCardCell.id)

        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self

        emptyView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(table)
        view.addSubview(emptyView)
        view.addSubview(composer)

        composerBottom = composer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),

            table.topAnchor.constraint(equalTo: header.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: composer.topAnchor),

            emptyView.topAnchor.constraint(equalTo: table.topAnchor),
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.bottomAnchor.constraint(equalTo: table.bottomAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBottom!
        ])

        observer = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleKeyboard(note)
        }
        runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickRunningHeader()
        }
        if let runningTimer { RunLoop.main.add(runningTimer, forMode: .common) }
        reloadFromApp()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        runningTimer?.invalidate()
    }

    func reloadFromApp() {
        let entries = app.currentTaskEntries
        rows = Self.buildRows(from: entries)
        if app.activeTaskId != nil, !app.fileChanges.isEmpty {
            rows.append(.files(app.fileChanges))
        }
        let signature = rows.map(\.rowId).joined(separator: "|") + "#\(app.messages.count)#\(app.fileChanges.count)"
        let changed = signature != lastSignature
        lastSignature = signature

        header.configure(
            mode: app.activeTaskId == nil ? .home : .chat,
            title: app.activeTask?.title ?? "",
            model: app.pillModelName,
            thought: app.pillThoughtZh,
            connected: app.connection.isConnected
        )
        let showEmpty = app.activeTaskId == nil || rows.isEmpty
        emptyView.isHidden = !showEmpty
        emptyView.configure(device: app.deviceName, workspace: app.relay.selectedWorkspaceLabel, connected: app.connection.isConnected)
        composer.running = app.isTaskRunning
        composer.placeholderText = app.activeTaskId == nil ? "向 ZCode 提问…" : "提出后续修改要求…"

        if changed {
            table.reloadData()
            if needsScrollBottom {
                scrollToBottom(animated: false)
                needsScrollBottom = false
            }
        }
        view.backgroundColor = ZUIColor.canvas(traitCollection)
    }

    private var needsScrollBottom = true

    private static func buildRows(from entries: [ChatEntry]) -> [ChatRow] {
        var rows: [ChatRow] = []
        for entry in entries {
            switch entry.kind {
            case .user(let text, let time):
                rows.append(.user(id: entry.id, text: text, time: time))
            case .work(let id, let items, let startMs, let endMs, let running):
                rows.append(.work(id: id, items: items, startMs: startMs, endMs: endMs, running: running))
            case .body(let id, let markdown, _):
                let segments = MarkdownRenderer.segments(from: markdown)
                var textChunks: [String] = []
                func flush(_ index: Int) {
                    // 段落之间必须保留换行，否则标题/表格失效压成一坨。
                    let joined = textChunks.joined(separator: "\n\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty {
                        rows.append(.text(id: "\(id)-t\(index)", markdown: joined))
                    }
                    textChunks.removeAll()
                }
                for (index, segment) in segments.enumerated() {
                    switch segment.kind {
                    case .code:
                        flush(index)
                        rows.append(.web(id: "\(id)-c\(index)", code: segment.text, language: "code"))
                    case .mermaid:
                        flush(index)
                        rows.append(.web(id: "\(id)-m\(index)", code: segment.text, language: "mermaid"))
                    case .table(let tableRows):
                        flush(index)
                        var pipe = ""
                        for (rowIndex, cells) in tableRows.enumerated() {
                            pipe += "| " + cells.joined(separator: " | ") + " |\n"
                            if rowIndex == 0 { pipe += "| --- |\n" }
                        }
                        rows.append(.text(id: "\(id)-tb\(index)", markdown: pipe))
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
                flush(segments.count)            }
        }
        return rows
    }

    // MARK: - Table

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        switch row {
        case .user(let id, let text, let time):
            let cell = tableView.dequeueReusableCell(withIdentifier: UserCell.id, for: indexPath) as! UserCell
            cell.configure(text: text, time: time, trait: traitCollection)
            return cell
        case .work(let id, let items, let startMs, let endMs, let running):
            let cell = tableView.dequeueReusableCell(withIdentifier: WorkCell.id, for: indexPath) as! WorkCell
            cell.configure(
                id: id,
                items: items,
                startMs: startMs,
                endMs: endMs,
                running: running,
                expanded: expandedWorks.contains(id),
                expandedItems: expandedItems,
                trait: traitCollection,
                onToggleWork: { [weak self] in
                    guard let self else { return }
                    if self.expandedWorks.contains(id) {
                        self.expandedWorks.remove(id)
                    } else {
                        self.expandedWorks.insert(id)
                    }
                    self.table.beginUpdates()
                    self.table.reloadRows(at: [indexPath], with: .none)
                    self.table.endUpdates()
                },
                onToggleItem: { [weak self] itemId in
                    guard let self else { return }
                    if self.expandedItems.contains(itemId) {
                        self.expandedItems.remove(itemId)
                    } else {
                        self.expandedItems.insert(itemId)
                    }
                    self.table.beginUpdates()
                    self.table.reloadRows(at: [indexPath], with: .none)
                    self.table.endUpdates()
                }
            )
            return cell
        case .text(let id, let markdown):
            let cell = tableView.dequeueReusableCell(withIdentifier: BodyCell.id, for: indexPath) as! BodyCell
            cell.configure(markdown: markdown, trait: traitCollection)
            return cell
        case .files(let files):
            let cell = tableView.dequeueReusableCell(withIdentifier: FileCardCell.id, for: indexPath) as! FileCardCell
            cell.configure(files: files, trait: traitCollection,
                           onReview: { [weak self] in self?.onReviewFile?($0) },
                           onOpen: { [weak self] in self?.onOpenFile?($0) },
                           onUndo: { [weak self] in self?.app.showToast("已请求桌面端撤销本次更改") })
            return cell
        case .web(let id, let code, let language):
            let cell = tableView.dequeueReusableCell(withIdentifier: WebCell.id, for: indexPath) as! WebCell
            cell.onHeightChange = { [weak tableView] in
                tableView?.beginUpdates()
                tableView?.endUpdates()
            }
            cell.configure(code: code, language: language, trait: traitCollection)
            return cell
        }
    }

    // MARK: - Composer

    func composerDidChangeHeight(_ composer: ComposerView) {
        view.layoutIfNeeded()
        scrollToBottom(animated: false)
    }

    func composerDidTapSend(_ composer: ComposerView) {
        let text = composer.text
        composer.text = ""
        needsScrollBottom = true
        app.send(text)
    }

    func composerDidTapStop(_ composer: ComposerView) {
        app.relay.stopTask(app.activeTaskId)
    }

    func composerDidTapAttach(_ composer: ComposerView) {
        onOpenAttach?()
    }

    // MARK: - 其他

    private func scrollToBottom(animated: Bool) {
        let count = rows.count
        guard count > 0 else { return }
        table.scrollToRow(at: IndexPath(row: count - 1, section: 0), at: .bottom, animated: animated)
    }

    private func tickRunningHeader() {
        guard app.isTaskRunning else { return }
        for case .work(let id, _, _, _, let running) in rows where running {
            if let index = rows.firstIndex(where: { $0.rowId == id }),
               let cell = table.cellForRow(at: IndexPath(row: index, section: 0)) as? WorkCell {
                cell.refreshDurationIfVisible()
            }
        }
    }

    private func handleKeyboard(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(frame, from: nil)
        let overlap = max(0, view.safeAreaLayoutGuide.layoutFrame.maxY - local.minY)
        composerBottom?.constant = -overlap
        UIView.animate(withDuration: 0.22) { self.view.layoutIfNeeded() }
    }
}

extension ChatViewController.ChatRow {
    var rowId: String {
        switch self {
        case .user(let id, _, _): return id
        case .work(let id, _, _, _, _): return id
        case .text(let id, _): return id
        case .web(let id, _, _): return id
        }
    }
}

// MARK: - 头部

final class ChatHeader: UIView {
    enum Mode { case home, chat }

    var onMenu: (() -> Void)?
    var onBack: (() -> Void)?
    var onPill: (() -> Void)?
    var onNew: (() -> Void)?

    private let menuButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let pill = UIButton(type: .system)
    private let newButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        func round(_ button: UIButton, symbol: String, radius: CGFloat = 12, tint: UIColor? = nil, bg: UIColor? = nil) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.backgroundColor = bg ?? ZUIColor.chip(UITraitCollection.current)
            button.layer.cornerRadius = radius
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.tintColor = tint ?? ZUIColor.ink(UITraitCollection.current)
        }
        round(menuButton, symbol: "line.3.horizontal")
        round(backButton, symbol: "chevron.left", bg: .clear)
        round(newButton, symbol: "square.and.pencil", radius: 12)

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = 18
        pill.backgroundColor = ZUIColor.chip(UITraitCollection.current)
        pill.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        pill.setTitleColor(ZUIColor.ink(UITraitCollection.current), for: .normal)
        pill.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        pill.semanticContentAttribute = .forceRightToLeft
        pill.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        pill.imageEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: -4)
        pill.tintColor = ZUIColor.inkSoft(UITraitCollection.current)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .bold)
        titleLabel.textColor = ZUIColor.ink(UITraitCollection.current)

        menuButton.addTarget(self, action: #selector(tapMenu), for: .touchUpInside)
        backButton.addTarget(self, action: #selector(tapBack), for: .touchUpInside)
        pill.addTarget(self, action: #selector(tapPill), for: .touchUpInside)
        newButton.addTarget(self, action: #selector(tapNew), for: .touchUpInside)

        addSubview(titleLabel)
        addSubview(menuButton)
        addSubview(backButton)
        addSubview(pill)
        addSubview(newButton)
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.trailingAnchor.constraint(equalTo: newButton.leadingAnchor, constant: -8),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 36),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pill.leadingAnchor, constant: -8)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func applyColors() {
        let trait = traitCollection
        menuButton.backgroundColor = ZUIColor.chip(trait)
        menuButton.tintColor = ZUIColor.ink(trait)
        backButton.tintColor = ZUIColor.ink(trait)
        newButton.backgroundColor = ZUIColor.chip(trait)
        newButton.tintColor = ZUIColor.ink(trait)
        pill.backgroundColor = ZUIColor.chip(trait)
        pill.setTitleColor(ZUIColor.ink(trait), for: .normal)
        pill.tintColor = ZUIColor.inkSoft(trait)
        titleLabel.textColor = ZUIColor.ink(trait)
    }

    func configure(mode: Mode, title: String, model: String, thought: String, connected: Bool) {
        let isHome = mode == .home
        menuButton.isHidden = !isHome
        backButton.isHidden = isHome
        titleLabel.isHidden = isHome
        titleLabel.text = title
        let shortModel = model.count > 12 ? String(model.prefix(12)) + "…" : model
        let pillText = NSAttributedString(string: " \(shortModel) · \(thought) ", attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        pill.setAttributedTitle(pillText, for: .normal)
        pill.isEnabled = connected
        pill.alpha = connected ? 1 : 0.45
        applyColors()
    }

    @objc private func tapMenu() { onMenu?() }
    @objc private func tapBack() { onBack?() }
    @objc private func tapPill() { onPill?() }
    @objc private func tapNew() { onNew?() }
}

// MARK: - 空状态

final class ChatEmptyView: UIView {
    private let logo = UILabel()
    private let greeting = UILabel()
    private let sub = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.text = "Z"
        logo.textColor = .white
        logo.font = .systemFont(ofSize: 34, weight: .heavy)
        logo.textAlignment = .center
        logo.backgroundColor = ZUIColor.ink(UITraitCollection.current)
        logo.layer.cornerRadius = 24
        logo.clipsToBounds = true

        greeting.translatesAutoresizingMaskIntoConstraints = false
        greeting.font = .systemFont(ofSize: 21, weight: .bold)
        greeting.textAlignment = .center
        greeting.numberOfLines = 0

        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = ZUIColor.inkSoft(UITraitCollection.current)
        sub.textAlignment = .center

        addSubview(logo)
        addSubview(greeting)
        addSubview(sub)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -58),
            logo.widthAnchor.constraint(equalToConstant: 76),
            logo.heightAnchor.constraint(equalToConstant: 76),
            greeting.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 22),
            greeting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            greeting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            sub.topAnchor.constraint(equalTo: greeting.bottomAnchor, constant: 10),
            sub.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            sub.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func applyColors() {
        let trait = traitCollection
        logo.backgroundColor = ZUIColor.ink(trait)
        greeting.textColor = ZUIColor.ink(trait)
        sub.textColor = ZUIColor.inkSoft(trait)
    }

    func configure(device: String, workspace: String?, connected: Bool) {
        let hour = Calendar.current.component(.hour, from: Date())
        let text: String
        switch hour {
        case 5..<11: text = "早上好，准备好开工了吗"
        case 11..<13: text = "中午好，休息一下再继续"
        case 13..<18: text = "下午好，今天要做点什么"
        case 18..<23: text = "晚上好，今天想完成什么"
        default: text = "夜深啦，别忘了照顾好自己哦"
        }
        greeting.text = text
        let place = workspace?.split(separator: "\\").last.map(String.init) ?? workspace ?? ""
        sub.text = connected ? "已连接 \(device)\(place.isEmpty ? "" : " · \(place)")" : "尚未连接桌面端"
    }
}

// MARK: - 用户气泡

final class UserCell: UITableViewCell {
    static let id = "user"
    private let bubble = UIView()
    private let label = UITextView()
    private let meta = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isScrollEnabled = false
        label.backgroundColor = .clear
        label.textContainerInset = .zero
        label.textContainer.lineFragmentPadding = 0
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.font = .systemFont(ofSize: 11.5)
        meta.textColor = ZUIColor.inkFaint(UITraitCollection.current)

        contentView.addSubview(bubble)
        bubble.addSubview(label)
        contentView.addSubview(meta)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            bubble.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
            meta.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 5),
            meta.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            meta.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(text: String, time: Int, trait: UITraitCollection) {
        label.attributedText = MarkdownRenderer.attributed(from: text, trait: trait, user: false)
        bubble.backgroundColor = ZUIColor.chip(trait)
        meta.text = "复制   \(TimeFormat.clock(time))"
    }
}

// MARK: - 已工作折叠时间线

final class WorkCell: UITableViewCell {
    static let id = "work"
    private var onToggleWork: (() -> Void)?
    private var onToggleItem: ((String) -> Void)?
    private var itemHandlers: [UIButton: String] = [:]
    private var workId = ""
    private var startMs = 0
    private var endMs = 0
    private var running = false
    private var expanded = false

    private let headerButton = UIButton(type: .system)
    private let container = UIStackView()
    private let chevron = UIImageView()
    private let leftBar = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        headerButton.contentHorizontalAlignment = .left
        headerButton.addTarget(self, action: #selector(tapHeader), for: .touchUpInside)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        chevron.tintColor = ZUIColor.inkFaint(UITraitCollection.current)
        chevron.contentMode = .scaleAspectFit

        leftBar.translatesAutoresizingMaskIntoConstraints = false
        leftBar.layer.cornerRadius = 1

        container.translatesAutoresizingMaskIntoConstraints = false
        container.axis = .vertical
        container.spacing = 10
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 2, right: 4)

        contentView.addSubview(headerButton)
        contentView.addSubview(chevron)
        contentView.addSubview(leftBar)
        contentView.addSubview(container)
        NSLayoutConstraint.activate([
            headerButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            headerButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerButton.heightAnchor.constraint(equalToConstant: 22),
            chevron.centerYAnchor.constraint(equalTo: headerButton.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: headerButton.trailingAnchor, constant: 2),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            leftBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 19),
            leftBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            leftBar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            leftBar.widthAnchor.constraint(equalToConstant: 2),
            container.topAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: 2),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        let trait = traitCollection
        headerButton.setTitleColor(ZUIColor.inkSoft(trait), for: .normal)
        chevron.tintColor = ZUIColor.inkFaint(trait)
        leftBar.backgroundColor = ZUIColor.line(trait)
    }

    func configure(
        id: String,
        items: [WorkItem],
        startMs: Int,
        endMs: Int,
        running: Bool,
        expanded: Bool,
        expandedItems: Set<String>,
        trait: UITraitCollection,
        onToggleWork: @escaping () -> Void,
        onToggleItem: @escaping (String) -> Void
    ) {
        self.workId = id
        self.startMs = startMs
        self.endMs = endMs
        self.running = running
        self.expanded = expanded
        self.onToggleWork = onToggleWork
        self.onToggleItem = onToggleItem

        headerButton.setTitle("  已工作 \(durationText())", for: .normal)
        headerButton.setTitleColor(ZUIColor.inkSoft(trait), for: .normal)
        headerButton.titleLabel?.font = .systemFont(ofSize: 13)
        chevron.image = UIImage(
            systemName: expanded ? "chevron.up" : "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
        )
        chevron.tintColor = ZUIColor.inkSoft(trait)
        container.isHidden = !expanded

        container.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard expanded else { return }

        for item in items {
            switch item.kind {
            case .thinking:
                container.addArrangedSubview(makeFoldRow(
                    symbol: "brain.head.profile",
                    title: item.title,
                    detail: item.detail,
                    monoDetail: false,
                    expanded: expandedItems.contains(item.id),
                    itemId: item.id,
                    trait: trait
                ))
            case .skill:
                container.addArrangedSubview(makeIconRow(
                    symbol: "wand.and.stars",
                    parts: [("技能 ", ZUIColor.inkSoft(trait), false), (item.title.replacingOccurrences(of: "技能 ", with: ""), ZUIColor.accent(trait), false)],
                    trait: trait
                ))
            case .read:
                container.addArrangedSubview(makeFoldRow(
                    symbol: "magnifyingglass",
                    title: item.title,
                    detail: item.detail.isEmpty ? nil : item.detail,
                    monoDetail: false,
                    expanded: expandedItems.contains(item.id),
                    itemId: item.id,
                    trait: trait
                ))
            case .edit:
                container.addArrangedSubview(makeFoldRow(
                    symbol: "square.and.pencil",
                    title: item.title,
                    detail: item.detail,
                    monoDetail: true,
                    expanded: expandedItems.contains(item.id),
                    itemId: item.id,
                    trait: trait
                ))
            case .terminal:
                let firstLine = item.detail.split(separator: "\n").first.map(String.init) ?? item.detail
                container.addArrangedSubview(makeFoldRow(
                    symbol: "terminal",
                    title: firstLine,
                    detail: item.detail,
                    monoDetail: true,
                    expanded: expandedItems.contains(item.id),
                    itemId: item.id,
                    trait: trait
                ))
            case .text:
                container.addArrangedSubview(makePlainRow(item.detail, trait: trait))
            }
        }
    }

    func refreshDurationIfVisible() {
        headerButton.setTitle("  已工作 \(durationText())", for: .normal)
    }

    private func durationText() -> String {
        if running {
            let seconds = Int(Date().timeIntervalSince1970 * 1000) - startMs
            return TimeFormat.duration(seconds: max(1, seconds / 1000))
        }
        guard startMs > 0, endMs > 0 else { return "" }
        let seconds = max(1, (endMs - startMs) / 1000)
        return TimeFormat.duration(seconds: seconds)
    }

    @objc private func tapHeader() { onToggleWork?() }

    /// 折叠行（网页版同款）：标题 + 小箭头，点开看详情。
    private func makeFoldRow(
        symbol: String,
        title: String,
        detail: String?,
        monoDetail: Bool,
        expanded: Bool,
        itemId: String,
        trait: UITraitCollection
    ) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let head = UIButton(type: .system)
        head.translatesAutoresizingMaskIntoConstraints = false
        head.contentHorizontalAlignment = .left
        head.setTitle("  " + title, for: .normal)
        head.setTitleColor(ZUIColor.inkSoft(trait), for: .normal)
        head.titleLabel?.font = .systemFont(ofSize: 12.5)
        head.addTarget(self, action: #selector(tapItem(_:)), for: .touchUpInside)

        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = ZUIColor.inkSoft(trait)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit

        let arrow = UIImageView(
            image: UIImage(
                systemName: expanded ? "chevron.up" : "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
            )
        )
        arrow.tintColor = ZUIColor.inkFaint(trait)
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.contentMode = .scaleAspectFit

        wrap.addSubview(icon)
        wrap.addSubview(head)
        wrap.addSubview(arrow)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            head.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            head.topAnchor.constraint(equalTo: wrap.topAnchor),
            head.heightAnchor.constraint(equalToConstant: 20),
            head.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -4),
            arrow.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 11),
            arrow.heightAnchor.constraint(equalToConstant: 11),
            arrow.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor)
        ])

            if let detail, !detail.isEmpty {
                let body = UILabel()
                body.translatesAutoresizingMaskIntoConstraints = false
                body.font = monoDetail
                    ? .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                    : .systemFont(ofSize: 13)
                body.textColor = ZUIColor.inkSoft(trait)
                body.numberOfLines = expanded ? 24 : 1
                body.text = expanded ? "  " + detail.replacingOccurrences(of: "\n", with: "\n  ") : detail
                if expanded {
                    body.backgroundColor = ZUIColor.surface(trait)
                    body.layer.cornerRadius = 8
                    body.clipsToBounds = true
                }
            wrap.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4),
                body.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 20),
                body.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
            ])
        } else {
            head.bottomAnchor.constraint(equalTo: wrap.bottomAnchor).isActive = true
        }
        itemHandlers[head] = itemId
        return wrap
    }

    @objc private func tapItem(_ sender: UIButton) {
        if let id = itemHandlers[sender] {
            onToggleItem?(id)
        }
    }

    private func makeIconRow(symbol: String, parts: [(String, UIColor, Bool)], trait: UITraitCollection) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = ZUIColor.inkSoft(trait)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        row.addArrangedSubview(icon)
        for (text, color, mono) in parts {
            let label = UILabel()
            label.text = text
            label.textColor = color
            label.font = mono
                ? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
                : .systemFont(ofSize: 12.5)
            label.numberOfLines = 1
            row.addArrangedSubview(label)
        }
        return row
    }

    private func makePlainRow(_ text: String, trait: UITraitCollection) -> UIView {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13.5)
        label.textColor = ZUIColor.ink(trait)
        label.numberOfLines = 0
        label.text = text
        return label
    }
}

// MARK: - 正文

final class BodyCell: UITableViewCell {
    static let id = "body"
    private let label = UITextView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isScrollEnabled = false
        label.backgroundColor = .clear
        label.textContainerInset = .zero
        label.textContainer.lineFragmentPadding = 0
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
    }

    func configure(markdown: String, trait: UITraitCollection) {
        label.attributedText = MarkdownRenderer.attributed(from: markdown, trait: trait, user: false)
    }
}

// MARK: - 文件更改卡片（审查/打开走侧边栏）

final class FileCardCell: UITableViewCell {
    static let id = "files"
    private let card = UIView()
    private let header = UILabel()
    private let rowsStack = UIStackView()
    private var onReview: ((FileChangeInfo) -> Void)?
    private var onOpen: ((FileChangeInfo) -> Void)?
    private var buttonFiles: [UIButton: FileChangeInfo] = [:]
    private var buttonModes: [UIButton: String] = [:]

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        header.translatesAutoresizingMaskIntoConstraints = false
        header.font = .systemFont(ofSize: 13)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.axis = .vertical
        contentView.addSubview(card)
        card.addSubview(header)
        card.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -12),
            rowsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            rowsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyChrome()
    }

    private func applyChrome() {
        let t = traitCollection
        card.backgroundColor = ZUIColor.surface(t)
        card.layer.borderColor = ZUIColor.line(t).cgColor
        header.textColor = ZUIColor.ink(t)
    }

    func configure(files: [FileChangeInfo], trait: UITraitCollection,
                   onReview: @escaping (FileChangeInfo) -> Void,
                   onOpen: @escaping (FileChangeInfo) -> Void,
                   onUndo: @escaping () -> Void) {
        self.onReview = onReview
        self.onOpen = onOpen
        buttonFiles.removeAll()
        buttonModes.removeAll()
        applyChrome()
        let adds = files.reduce(0) { $0 + $1.additions }
        let dels = files.reduce(0) { $0 + $1.deletions }
        let text = NSMutableAttributedString(string: "  \(files.count) 个文件已更改  ", attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: ZUIColor.ink(trait)
        ])
        text.append(NSAttributedString(string: "+\(adds)", attributes: [
            .font: UIFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: ZUIColor.ok
        ]))
        text.append(NSAttributedString(string: "  -\(dels)", attributes: [
            .font: UIFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: ZUIColor.danger
        ]))
        header.attributedText = text

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for file in files.prefix(12) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 8
            row.isLayoutMarginsRelativeArrangement = true
            row.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            row.layer.cornerRadius = 0

            let sep = UIView()
            sep.backgroundColor = ZUIColor.line(trait)
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.heightAnchor.constraint(equalToConstant: 0.7).isActive = true
            rowsStack.addArrangedSubview(sep)

            let icon = UILabel()
            icon.text = "📝"
            icon.font = .systemFont(ofSize: 12)
            row.addArrangedSubview(icon)

            let name = UILabel()
            let base = file.path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? file.path
            name.text = base
            name.font = .systemFont(ofSize: 12.5, weight: .semibold)
            name.textColor = ZUIColor.ink(trait)
            name.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(name)

            let dir = UILabel()
            let dirPath = (file.path as NSString)
            let dirShort = dirPath.length > base.count
                ? String(dirPath.substring(to: dirPath.length - base.count - 1))
                : ""
            dir.text = dirShort
            dir.font = .systemFont(ofSize: 10.5)
            dir.textColor = ZUIColor.inkFaint(trait)
            dir.lineBreakMode = .byTruncatingMiddle
            dir.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(dir)

            if file.additions > 0 {
                let add = UILabel()
                add.text = "+\(file.additions)"
                add.font = .systemFont(ofSize: 11.5, weight: .semibold)
                add.textColor = ZUIColor.ok
                row.addArrangedSubview(add)
            }
            if file.deletions > 0 {
                let del = UILabel()
                del.text = "-\(file.deletions)"
                del.font = .systemFont(ofSize: 11.5, weight: .semibold)
                del.textColor = ZUIColor.danger
                row.addArrangedSubview(del)
            }

            func actionButton(_ title: String, mode: String) -> UIButton {
                let b = UIButton(type: .system)
                b.setTitle(title, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
                b.setTitleColor(ZUIColor.ink(trait), for: .normal)
                b.layer.borderWidth = 1
                b.layer.borderColor = ZUIColor.line(trait).cgColor
                b.layer.cornerRadius = 9
                b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 11, bottom: 4, right: 11)
                row.addArrangedSubview(b)
                return b
            }
            let review = actionButton("审查", mode: "diff")
            review.addTarget(self, action: #selector(tapReview(_:)), for: .touchUpInside)
            let open = actionButton("打开", mode: "file")
            open.addTarget(self, action: #selector(tapOpen(_:)), for: .touchUpInside)
            buttonFiles[review] = file
            buttonModes[review] = "diff"
            buttonFiles[open] = file
            buttonModes[open] = "file"
        }

        let undoRow = UIView()
        undoRow.translatesAutoresizingMaskIntoConstraints = false
        undoRow.backgroundColor = .clear
        let undo = UIButton(type: .system)
        undo.translatesAutoresizingMaskIntoConstraints = false
        undo.setTitle("⟲ 撤销", for: .normal)
        undo.titleLabel?.font = .systemFont(ofSize: 12.5)
        undo.setTitleColor(ZUIColor.inkSoft(trait), for: .normal)
        undo.addTarget(self, action: #selector(tapUndo), for: .touchUpInside)
        undoRow.addSubview(undo)
        NSLayoutConstraint.activate([
            undo.topAnchor.constraint(equalTo: undoRow.topAnchor, constant: 6),
            undo.bottomAnchor.constraint(equalTo: undoRow.bottomAnchor, constant: -6),
            undo.trailingAnchor.constraint(equalTo: undoRow.trailingAnchor, constant: -12),
            undoRow.heightAnchor.constraint(equalToConstant: 32)
        ])
        rowsStack.addArrangedSubview(undoRow)
    }

    @objc private func tapReview(_ sender: UIButton) {
        if let file = buttonFiles[sender] { onReview?(file) }
    }

    @objc private func tapOpen(_ sender: UIButton) {
        if let file = buttonFiles[sender] { onOpen?(file) }
    }
}
