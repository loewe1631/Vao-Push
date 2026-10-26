import SwiftUI
import VaoPushCore

struct MessageCardEditor: View {
    let model: PrototypeModel
    let isNew: Bool
    let manageServers: () -> Void
    let onFinish: (() -> Void)?
    @State private var draft: CardConfiguration
    @State private var options: MessageCardOptions
    @State private var sourceOwner: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: PrototypeModel, style: MessageCardStyle, manageServers: @escaping () -> Void,
         onFinish: @escaping () -> Void) {
        self.model = model; self.isNew = true; self.manageServers = manageServers; self.onFinish = onFinish
        _draft = State(initialValue: .messageCard(name: style.title, style: style))
        _options = State(initialValue: MessageCardOptions(style: style))
        _sourceOwner = State(initialValue: "")
    }
    init(model: PrototypeModel, entry: SavedCard) {
        self.model = model; self.isNew = false; self.manageServers = {}; self.onFinish = nil
        _draft = State(initialValue: entry.card)
        _options = State(initialValue: entry.card.message ?? MessageCardOptions())
        _sourceOwner = State(initialValue: entry.source.owner)
    }
    private var sources: [ContentSource] {
        model.sources.filter { !$0.isDemo && ($0.isEnabled || (!isNew && $0.owner == sourceOwner)) }
    }
    private var selected: ContentSource? { sources.first { $0.owner == sourceOwner } }
    private var history: [ArchivedMessage] { model.messageHistory(owner: sourceOwner) }
    private var previewCard: CardConfiguration {
        var card = draft; card.message = options; return card
    }
    var body: some View {
        Form {
            Section(VaoL10n.text("排版预览")) {
                MessageCardView(card: previewCard, messages: history, sourceName: selected?.name ?? VaoL10n.text("消息来源"),
                    preview: history.isEmpty)
                    .frame(maxWidth: .infinity, minHeight: options.style == .list ? 190 : 170, alignment: .topLeading)
                    .padding(.vertical, 8)
                if history.isEmpty { Text(VaoL10n.text("这里仅展示布局占位，保存后等待真实消息。")).font(.caption).foregroundStyle(.secondary) }
            }
            Section(VaoL10n.text("消息来源")) {
                Picker(VaoL10n.text("服务器"), selection: $sourceOwner) {
                    Text(VaoL10n.text("请选择服务器")).tag("")
                    ForEach(sources) { Text($0.name).tag($0.owner) }
                }.disabled(!isNew)
                if sources.isEmpty {
                    Text(VaoL10n.text("连接服务器后，即可用收到的消息创建卡片。")).foregroundStyle(.secondary)
                    Button(VaoL10n.text("管理服务器"), action: manageServers)
                }
            }
            Section(VaoL10n.text("名称与排版")) {
                TextField(VaoL10n.text("卡片名称"), text: $draft.name).accessibilityIdentifier("message-card-name")
                Picker(VaoL10n.text("模板"), selection: $options.style) {
                    ForEach(MessageCardStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker(VaoL10n.text("外观"), selection: Binding(get: { draft.theme ?? .system }, set: { draft.theme = $0 })) {
                    Text(VaoL10n.text("跟随系统")).tag(CardConfiguration.Theme.system)
                    Text(VaoL10n.text("浅色")).tag(CardConfiguration.Theme.light)
                    Text(VaoL10n.text("深色")).tag(CardConfiguration.Theme.dark)
                }
                Toggle(VaoL10n.text("显示消息内容"), isOn: $options.showBody)
                Toggle(VaoL10n.text("显示接收时间"), isOn: $options.showTime)
            }
            Section {
                Text(VaoL10n.text("本机模板只显示最近收到的消息。行情、服务器状态等数据卡片，请在Web设计后通过订阅码导入。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(isNew ? VaoL10n.text("新建消息卡片") : VaoL10n.text("编辑消息卡片"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if isNew { ToolbarItem(placement: .cancellationAction) { Button(VaoL10n.text("取消"), action: finish) } }
            ToolbarItem(placement: .confirmationAction) {
                Button(VaoL10n.text("保存")) {
                    guard let source = selected else { return }
                    var card = draft; card.name = card.name.trimmingCharacters(in: .whitespacesAndNewlines); card.message = options
                    do { try model.save(card, source: source); finish() }
                    catch { self.error = error.localizedDescription }
                }.bold().disabled(selected == nil || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-message-card")
            }
        }
        .onAppear { if sourceOwner.isEmpty { sourceOwner = sources.first?.owner ?? "" } }
        .onChange(of: sources.map(\.owner)) { _, owners in if isNew && !owners.contains(sourceOwner) { sourceOwner = owners.first ?? "" } }
        .alert(VaoL10n.text("无法保存"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(VaoL10n.text("知道了")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func finish() { if let onFinish { onFinish() } else { dismiss() } }
}

struct MessageTemplateTile: View {
    let style: MessageCardStyle
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MessageCardView(card: .messageCard(name: style.title, style: style), messages: [], sourceName: "",
                compact: true, preview: true)
                .frame(maxWidth: .infinity).frame(height: 130).padding(14)
                .background(VaoTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VaoTheme.line, lineWidth: 1))
            Text(style.detail).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}
