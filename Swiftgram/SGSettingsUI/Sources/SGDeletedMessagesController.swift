import Foundation
import UIKit
import AsyncDisplayKit
import Display
import AccountContext
import TelegramPresentationData
import SGDeletedMessagesStore

public final class SGDeletedMessagesController: ViewController {
    private let context: AccountContext
    private let peerId: Int64?
    private var presentationData: PresentationData
    
    private var messages: [DeletedMessage] = []
    private var groupedMessages: [(chatTitle: String, messages: [DeletedMessage])] = []
    private var tableView: UITableView?
    private var emptyLabel: UILabel?
    
    private var showGrouped: Bool {
        return peerId == nil
    }
    
    public init(context: AccountContext, peerId: Int64? = nil) {
        self.context = context
        self.peerId = peerId
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        
        self.title = "Deleted Messages"
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear All", style: .plain, target: self, action: #selector(self.clearAllPressed))
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
    }
    
    override public func displayNodeDidLoad() {
        super.displayNodeDidLoad()
        
        let theme = self.presentationData.theme
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(DeletedMessageCell.self, forCellReuseIdentifier: DeletedMessageCell.reuseIdentifier)
        tableView.backgroundColor = theme.list.blocksBackgroundColor
        tableView.separatorColor = theme.list.itemBlocksSeparatorColor
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        self.tableView = tableView
        self.displayNode.view.addSubview(tableView)
        
        let emptyLabel = UILabel()
        emptyLabel.text = "No deleted messages saved yet"
        emptyLabel.textColor = theme.list.freeTextColor
        emptyLabel.font = UIFont.systemFont(ofSize: 17)
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        self.emptyLabel = emptyLabel
        self.displayNode.view.addSubview(emptyLabel)
        
        self.loadMessages()
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        let insets = layout.insets(options: [.statusBar, .input])
        let navBarHeight = self.navigationLayout(layout: layout).navigationFrame.maxY
        let frame = CGRect(x: 0, y: navBarHeight, width: layout.size.width, height: layout.size.height - navBarHeight)
        
        self.tableView?.frame = frame
        self.tableView?.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: insets.bottom, right: 0)
        self.tableView?.scrollIndicatorInsets = self.tableView?.contentInset ?? .zero
        self.emptyLabel?.frame = frame
    }
    
    private func loadMessages() {
        let store = DeletedMessagesStore.shared
        self.messages = store.getDeletedMessages(forPeerId: self.peerId)
        
        if self.showGrouped {
            var grouped: [String: [DeletedMessage]] = [:]
            for message in self.messages {
                let title = message.chatTitle.isEmpty ? "Unknown Chat" : message.chatTitle
                grouped[title, default: []].append(message)
            }
            self.groupedMessages = grouped.map { (chatTitle: $0.key, messages: $0.value) }
                .sorted { ($0.messages.first?.deletedDate ?? 0) > ($1.messages.first?.deletedDate ?? 0) }
        }
        
        let isEmpty = self.messages.isEmpty
        self.emptyLabel?.isHidden = !isEmpty
        self.tableView?.isHidden = isEmpty
        self.navigationItem.rightBarButtonItem?.isEnabled = !isEmpty
        self.tableView?.reloadData()
    }
    
    @objc private func clearAllPressed() {
        let alert = UIAlertController(
            title: "Clear All",
            message: "Are you sure you want to delete all saved messages?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            if let peerId = self.peerId {
                DeletedMessagesStore.shared.clearForPeer(peerId: peerId)
            } else {
                DeletedMessagesStore.shared.clearAll()
            }
            self.loadMessages()
        }))
        self.present(alert, animated: true)
    }
    
    private func message(at indexPath: IndexPath) -> DeletedMessage? {
        if self.showGrouped {
            guard indexPath.section < self.groupedMessages.count else { return nil }
            let group = self.groupedMessages[indexPath.section]
            guard indexPath.row < group.messages.count else { return nil }
            return group.messages[indexPath.row]
        } else {
            guard indexPath.row < self.messages.count else { return nil }
            return self.messages[indexPath.row]
        }
    }
}

// MARK: - UITableViewDataSource & UITableViewDelegate

extension SGDeletedMessagesController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int {
        if self.showGrouped {
            return self.groupedMessages.count
        }
        return 1
    }
    
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if self.showGrouped {
            guard section < self.groupedMessages.count else { return 0 }
            return self.groupedMessages[section].messages.count
        }
        return self.messages.count
    }
    
    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if self.showGrouped, section < self.groupedMessages.count {
            return self.groupedMessages[section].chatTitle
        }
        return nil
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: DeletedMessageCell.reuseIdentifier, for: indexPath) as! DeletedMessageCell
        if let msg = self.message(at: indexPath) {
            cell.configure(with: msg, showChatTitle: self.showGrouped, theme: self.presentationData.theme)
        }
        return cell
    }
    
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

// MARK: - DeletedMessageCell

private final class DeletedMessageCell: UITableViewCell {
    static let reuseIdentifier = "DeletedMessageCell"
    
    private let iconLabel = UILabel()
    private let chatTitleLabel = UILabel()
    private let messageLabel = UILabel()
    private let dateLabel = UILabel()
    private let deletedDateLabel = UILabel()
    private let directionIndicator = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
        
        let topRow = UIStackView(arrangedSubviews: [iconLabel, chatTitleLabel, directionIndicator])
        topRow.axis = .horizontal
        topRow.spacing = 6
        topRow.alignment = .center
        
        iconLabel.font = UIFont.systemFont(ofSize: 14)
        iconLabel.text = "🗑️"
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)
        
        chatTitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        chatTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        
        directionIndicator.font = UIFont.systemFont(ofSize: 12)
        directionIndicator.setContentHuggingPriority(.required, for: .horizontal)
        
        stack.addArrangedSubview(topRow)
        
        messageLabel.font = UIFont.systemFont(ofSize: 15)
        messageLabel.numberOfLines = 0
        stack.addArrangedSubview(messageLabel)
        
        let bottomRow = UIStackView(arrangedSubviews: [dateLabel, deletedDateLabel])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8
        bottomRow.distribution = .equalSpacing
        
        dateLabel.font = UIFont.systemFont(ofSize: 12)
        deletedDateLabel.font = UIFont.systemFont(ofSize: 12)
        
        stack.addArrangedSubview(bottomRow)
    }
    
    func configure(with message: DeletedMessage, showChatTitle: Bool, theme: PresentationTheme) {
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        
        let secondaryColor = theme.list.itemSecondaryTextColor
        let accentColor = theme.list.itemDestructiveColor
        
        chatTitleLabel.textColor = theme.list.itemPrimaryTextColor
        messageLabel.textColor = theme.list.itemPrimaryTextColor
        dateLabel.textColor = secondaryColor
        deletedDateLabel.textColor = accentColor
        directionIndicator.textColor = secondaryColor
        
        if showChatTitle {
            let title = message.chatTitle.isEmpty ? "Unknown Chat" : message.chatTitle
            chatTitleLabel.text = title
            chatTitleLabel.isHidden = false
        } else {
            chatTitleLabel.isHidden = true
        }
        
        if message.text.isEmpty {
            messageLabel.text = "[Media or empty message]"
            messageLabel.textColor = secondaryColor
        } else {
            messageLabel.text = message.text
            messageLabel.textColor = theme.list.itemPrimaryTextColor
        }
        
        directionIndicator.text = message.isOutgoing ? "↗ Outgoing" : "↙ Incoming"
        
        let originalDate = Date(timeIntervalSince1970: TimeInterval(message.date))
        dateLabel.text = Self.dateFormatter.string(from: originalDate)
        
        let deletedDate = Date(timeIntervalSince1970: TimeInterval(message.deletedDate))
        deletedDateLabel.text = "Deleted \(Self.relativeTimeString(from: deletedDate))"
    }
    
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    
    private static func relativeTimeString(from date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
