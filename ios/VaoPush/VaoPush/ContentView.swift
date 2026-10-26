import SwiftUI
import VaoPushCore

struct ContentView: View {
    @Bindable var model: PrototypeModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tab = 0
    @State private var sourceFilter: String?
    @State private var search = ""
    @State private var creatingCard = false
    @State private var examplesExpanded = false
    @State private var visitedTabs: Set<Int> = [0]
    @State private var hasShownCache = false
    private let navigation = AppNavigation.shared
    @State private var messagePath: [String] = []

    private var cardColumns: [GridItem] {
        [GridItem(dynamicTypeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: 300), spacing: 20, alignment: .top)]
    }
    private var visibleCards: [SavedCard] { model.cards.filter { !$0.source.isDemo && (sourceFilter == nil || $0.source.owner == sourceFilter) } }
    private var savedExamples: [SavedCard] { model.cards.filter { $0.source.isDemo } }
    private var visibleStates: [ReceivedState] { model.snapshots.filter { sourceFilter == nil || $0.source.owner == sourceFilter } }
    private var visibleMessages: [ReceivedMessage] {
        model.messages.filter { entry in
            (sourceFilter == nil || entry.source.owner == sourceFilter) &&
            (search.isEmpty || entry.message.title.localizedCaseInsensitiveContains(search) ||
             entry.message.body.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { cardsPage }
                .tabItem { Label(VaoL10n.text("卡片"), systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack(path: $messagePath) {
                if visitedTabs.contains(1) {
                    messagesPage.navigationDestination(for: String.self) { id in
                        if let entry = model.messages.first(where: { $0.id == id }) {
                            MessageDetailView(entry: entry)
                        }
                    }
                }
            }
                .tabItem { Label(VaoL10n.text("消息"), systemImage: "bell") }.tag(1)
            NavigationStack { if visitedTabs.contains(2) { dataPage } }
                .tabItem { Label(VaoL10n.text("数据"), systemImage: "externaldrive") }.tag(2)
            NavigationStack { if visitedTabs.contains(3) { SettingsView(model: model) } }
                .tabItem { Label(VaoL10n.text("设置"), systemImage: "slider.horizontal.3") }.tag(3)
        }
        .onChange(of: tab) { _, selected in visitedTabs.insert(selected) }
        .onAppear { openNotificationMessages() }
        .onChange(of: navigation.pendingMessage != nil) { _, pending in
            if pending { openNotificationMessages() }
        }
        .tint(VaoTheme.accent)
        .onReceive(NotificationCenter.default.publisher(for: .vaoPushRegistrationChanged)) { _ in Task { await model.syncAll() } }
        .onReceive(NotificationCenter.default.publisher(for: .vaoPushContentReceived)) { _ in Task { await model.syncAll() } }
        .onChange(of: model.sources.map(\.owner)) { _, owners in
            if let sourceFilter, !owners.contains(sourceFilter) { self.sourceFilter = nil }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if hasShownCache { do { try model.reload() } catch { model.error = String(describing: error) } }
            hasShownCache = true
            await model.refreshNotificationStatus()
            while !Task.isCancelled {
                await model.syncAll()
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
        .alert(VaoL10n.text("操作未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(VaoL10n.text("知道了")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func openNotificationMessages() {
        guard let request = navigation.consumeMessage() else { return }
        search = ""
        sourceFilter = nil
        creatingCard = false
        visitedTabs.insert(1)
        tab = 1
        if let id = model.receiveNotificationTap(payload: request.payload, title: request.title, body: request.body) {
            messagePath = [id]
        } else {
            messagePath = []
        }
        Task { await model.syncAll() }
    }

    private var cardsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { tab = 3 } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack").font(.title3).foregroundStyle(VaoTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.connections.isEmpty ? VaoL10n.text("连接你的服务器") : VaoL10n.text("管理 {0} 台服务器", String(describing: model.connections.count)))
                                .font(.subheadline.weight(.semibold)).foregroundStyle(VaoTheme.text)
                            Text(model.connections.isEmpty ? VaoL10n.text("接收消息，持续更新桌面卡片") : VaoL10n.text("独立配置，同时接收，按来源查看"))
                                .font(.caption).foregroundStyle(VaoTheme.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(VaoTheme.secondary)
                    }.padding(16).background(VaoTheme.soft, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityIdentifier("manage-servers")
                sourcePicker
                if visibleCards.isEmpty {
                    ContentUnavailableView(VaoL10n.text("还没有卡片"), systemImage: "square.grid.2x2", description: Text(VaoL10n.text("点击右上角“＋”创建消息卡片，或通过订阅码导入Web卡片。")))
                }
                LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 20) {
                    ForEach(visibleCards) { entry in cardTile(entry) }
                }
                DisclosureGroup(isExpanded: $examplesExpanded) {
                    if examplesExpanded { exampleShowcase.padding(.top, 14) }
                } label: {
                    Label(VaoL10n.text("示例"), systemImage: "rectangle.stack").font(.headline)
                }
                .padding(18).background(VaoTheme.soft, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("card-examples")
                VStack(alignment: .leading, spacing: 8) {
                    Label(VaoL10n.text("把卡片添加到桌面"), systemImage: "square.grid.2x2").font(.headline)
                    Text(VaoL10n.text("长按桌面 → 编辑 → 添加小组件 → Vao Push。添加后编辑小组件，选择已保存的卡片；卡片名称旁会标明服务器来源。"))
                        .font(.subheadline).foregroundStyle(VaoTheme.secondary)
                    Label(VaoL10n.text("多张卡片滑动切换"), systemImage: "square.stack").font(.headline).padding(.top, 6)
                    Text(VaoL10n.text("分别添加相同尺寸的 Vao Push 小组件，为每个选择不同卡片，再将它们拖叠在一起。上下滑动叠放即可切换行情、服务器信息等卡片；只需手动切换时可关闭“智能轮换”。"))
                        .font(.subheadline).foregroundStyle(VaoTheme.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(VaoTheme.soft, in: RoundedRectangle(cornerRadius: 16))
            }.padding().frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .background(VaoTheme.background)
        .navigationTitle(VaoL10n.text("我的卡片"))
        .toolbar {
            Button { creatingCard = true } label: { Label(VaoL10n.text("新建卡片"), systemImage: "plus") }
                .accessibilityIdentifier("new-card")
        }
        .sheet(isPresented: $creatingCard) {
            NewCardFlow(model: model) {
                creatingCard = false
                tab = 3
            }
        }
    }

    @ViewBuilder private func cardTile(_ entry: SavedCard) -> some View {
        if entry.card.message != nil || model.snapshot(for: entry) != nil {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    if entry.card.message != nil {
                        MessageCardEditor(model: model, entry: entry)
                    } else if let snapshot = model.snapshot(for: entry) {
                        CardEditor(model: model, original: entry.card, snapshot: snapshot, source: entry.source)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        if entry.card.remote != nil {
                            Text(entry.card.name).font(.headline).foregroundStyle(VaoTheme.text)
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Group {
                            if entry.card.message != nil {
                                MessageCardView(card: entry.card, messages: model.messageHistory(owner: entry.source.owner), sourceName: entry.source.name)
                            } else if let snapshot = model.snapshot(for: entry) {
                                PrototypeCardView(card: entry.card, snapshot: snapshot, sourceName: entry.source.name, isDemo: entry.source.isDemo)
                            }
                        }
                            .foregroundStyle(VaoTheme.text)
                            .frame(maxWidth: .infinity, minHeight: 225, alignment: .topLeading).padding(20)
                            .background(VaoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(VaoTheme.line, lineWidth: 1))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                HStack {
                    SourceLabel(source: entry.source)
                    Spacer()
                    Menu {
                        if entry.card.message != nil {
                            Button(VaoL10n.text("复制为新卡片")) { model.duplicate(entry) }
                        }
                        Button(VaoL10n.text("删除卡片"), role: .destructive) { model.remove(entry) }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                }.padding(.horizontal, 6)
            }
        }
    }

    private var exampleShowcase: some View {
        let cards = PrototypeData.cards.map { original in
            var card = original; card.name = VaoL10n.text(card.name)
            card.fields = card.fields.map { original in
                var field = original
                if let alias = field.alias { field.alias = VaoL10n.text(alias) }
                return field
            }
            return card
        }
        let snapshots = PrototypeData.snapshots().map { original in
            var snapshot = original
            snapshot.state.fields = snapshot.state.fields?.mapValues { original in
                var field = original
                if let label = field.label { field.label = VaoL10n.text(label) }
                if case .text(let value) = field.value, field.type == .text { field.value = .text(VaoL10n.text(value)) }
                if let unit = field.unit { field.unit = VaoL10n.text(unit) }
                return field
            }
            snapshot.state.series = snapshot.state.series?.mapValues { original in
                var series = original
                if let label = series.label { series.label = VaoL10n.text(label) }
                return series
            }
            return snapshot
        }
        return VStack(alignment: .leading, spacing: 14) {
            Text(VaoL10n.text("仅展示卡片效果，示例数值不是实时数据。数据卡片可在Web设计后通过订阅码添加。"))
                .font(.caption).foregroundStyle(VaoTheme.secondary)
            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 20) {
                exampleSurface(MessageCardView(card: .messageCard(name: VaoL10n.text("最新消息")), messages: [], sourceName: VaoL10n.text("示例"), preview: true))
                if !savedExamples.contains(where: { $0.source.owner == PrototypeData.owner && $0.card.streamID == PrototypeData.quoteStream }) {
                    exampleSurface(PrototypeCardView(card: cards[0], snapshot: snapshots[0], sourceName: VaoL10n.text("示例"), isDemo: true))
                }
                if !savedExamples.contains(where: { $0.source.owner == PrototypeData.owner && $0.card.streamID == PrototypeData.taskStream }) {
                    exampleSurface(PrototypeCardView(card: cards[1], snapshot: snapshots[1], sourceName: VaoL10n.text("示例"), isDemo: true))
                }
                ForEach(savedExamples) { entry in cardTile(entry) }
            }
        }
    }

    private func exampleSurface<Content: View>(_ content: Content) -> some View {
        content.foregroundStyle(VaoTheme.text)
            .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading).padding(20)
            .background(VaoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(VaoTheme.line, lineWidth: 1))
    }

    private var messagesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourcePicker
                if visibleMessages.isEmpty {
                    ContentUnavailableView(VaoL10n.text("暂无消息"), systemImage: "bell", description: Text(VaoL10n.text("各服务器收到的消息会在这里汇总，也可以按来源筛选。")))
                }
                LazyVStack(spacing: 12) {
                    ForEach(visibleMessages) { entry in
                        NavigationLink(value: entry.id) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(entry.message.title).font(.headline).foregroundStyle(VaoTheme.text)
                                Text(entry.message.body).font(.subheadline).foregroundStyle(VaoTheme.secondary).lineLimit(3)
                                HStack {
                                    SourceLabel(source: entry.source)
                                    Spacer()
                                    if let date = ProtocolRules.date(entry.message.receivedAt) {
                                        Text(date, style: .time).font(.caption2).foregroundStyle(VaoTheme.secondary)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                .background(VaoTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(VaoTheme.line, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding().frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(VaoTheme.background).navigationTitle(VaoL10n.text("消息"))
            .searchable(text: $search, prompt: VaoL10n.text("搜索消息"))
            .refreshable { await model.syncAll() }
            .toolbar {
                Button {
                    Task { await model.syncAll() }
                } label: { Label(VaoL10n.text("同步消息"), systemImage: "arrow.clockwise") }
                .disabled(!model.syncing.isEmpty)
            }
    }

    private var dataPage: some View {
        List {
            Section { sourcePicker }
            if visibleStates.isEmpty {
                ContentUnavailableView(VaoL10n.text("等待数据"), systemImage: "externaldrive", description: Text(VaoL10n.text("连接服务器并发送卡片数据后，这里会显示收到的内容。")))
            }
            ForEach(visibleStates) { entry in
                NavigationLink {
                    Form {
                        Section {
                            SourceLabel(source: entry.source)
                            LabeledContent(VaoL10n.text("数据 ID"), value: entry.snapshot.dataID)
                            LabeledContent(VaoL10n.text("版本"), value: entry.snapshot.revision)
                            LabeledContent(VaoL10n.text("来源时间"), value: entry.snapshot.state.sourceUpdatedAt)
                        }
                        Section(VaoL10n.text("字段")) {
                            ForEach((entry.snapshot.state.fields ?? [:]).keys.sorted(), id: \.self) { key in
                                let field = entry.snapshot.state.fields?[key]
                                LabeledContent(field?.label ?? key, value: FieldFormatter.display(field, decimals: nil))
                            }
                        }
                        Section {
                            Text(VaoL10n.text("在Web设计数据卡片并生成订阅码，再到“卡片 → ＋”导入。手机本机模板用于展示最近消息。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.navigationTitle(model.displayName(for: entry))
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.displayName(for: entry)).font(.headline)
                        SourceLabel(source: entry.source)
                        Text(VaoL10n.text("第 {0} 版", String(describing: entry.snapshot.revision))).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }
        }.scrollContentBackground(.hidden).background(VaoTheme.background).navigationTitle(VaoL10n.text("数据"))
    }

    private var sourcePicker: some View {
        Picker(VaoL10n.text("来源"), selection: $sourceFilter) {
            Text(VaoL10n.text("全部来源")).tag(String?.none)
            ForEach(model.sources.filter { !$0.isDemo }) { source in Text(source.name).tag(Optional(source.owner)) }
        }.pickerStyle(.menu).accessibilityIdentifier("source-filter")
    }
}

private struct MessageDetailView: View {
    let entry: ReceivedMessage
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SourceLabel(source: entry.source)
                Text(entry.message.title).font(.title2.bold()).textSelection(.enabled)
                Text(entry.message.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let date = ProtocolRules.date(entry.message.receivedAt) {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 760, alignment: .leading).padding().frame(maxWidth: .infinity)
        }.navigationTitle(VaoL10n.text("消息详情")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct NewCardFlow: View {
    let model: PrototypeModel
    let manageServers: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ImportWebCardView(model: model, onFinish: { dismiss() })
                    } label: { Label(VaoL10n.text("通过订阅码导入Web卡片"), systemImage: "link.badge.plus") }
                        .accessibilityIdentifier("import-web-card")
                }
                Section {
                    ForEach(MessageCardStyle.allCases) { style in
                        NavigationLink {
                            MessageCardEditor(model: model, style: style, manageServers: manageServers, onFinish: { dismiss() })
                        } label: { MessageTemplateTile(style: style) }
                            .accessibilityIdentifier("message-template-\(style.rawValue)")
                    }
                } header: { Text(VaoL10n.text("本机消息模板")) } footer: {
                    Text(VaoL10n.text("仅展示排版占位，保存后显示所选服务器最近收到的消息。行情、服务器状态、进度等数据卡片统一在Web创建，再通过订阅码导入。"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(VaoTheme.background)
            .navigationTitle(VaoL10n.text("新建卡片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(VaoL10n.text("取消")) { dismiss() } }
            }
        }.tint(VaoTheme.accent)
    }

}

private struct ImportWebCardView: View {
    let model: PrototypeModel
    let onFinish: () -> Void
    @State private var server = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    private var connections: [ServerConnection] { model.connections.filter { $0.isEnabled && !$0.isDemo && $0.bindingID != nil } }
    var body: some View {
        Form {
            Section {
                Picker(VaoL10n.text("卡片所属服务器"), selection: $server) {
                    Text(VaoL10n.text("请选择服务器")).tag("")
                    ForEach(connections) { Text($0.name).tag($0.id) }
                }
                TextField(VaoL10n.text("粘贴订阅码或链接"), text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("card-subscription-code")
            } footer: { Text(VaoL10n.text("在Web发布卡片后复制订阅码。导入完整设计，后续跟随更新；也可在手机做独立微调。")) }
            if connections.isEmpty { Text(VaoL10n.text("请先在设置中连接卡片所属的服务器。")) }
            if let error { Text(error).foregroundStyle(.red) }
            Button(busy ? VaoL10n.text("正在导入…") : VaoL10n.text("导入卡片")) {
                busy = true; error = nil
                Task {
                    do { try await model.importCard(connectionID: server, code: code); onFinish() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy || server.isEmpty || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("redeem-card-code")
        }.navigationTitle(VaoL10n.text("导入Web卡片")).navigationBarTitleDisplayMode(.inline)
            .onAppear { if server.isEmpty { server = connections.first?.id ?? "" } }
            .onChange(of: connections.map(\.id)) { _, ids in if !ids.contains(server) { server = ids.first ?? "" } }
            .interactiveDismissDisabled(busy)
    }
}

struct SourceLabel: View {
    let source: ContentSource
    var body: some View {
        Label(source.name + (source.isEnabled ? "" : VaoL10n.text(" · 已停用")), systemImage: source.isDemo ? "testtube.2" : "server.rack")
            .font(.caption).foregroundStyle(VaoTheme.secondary).lineLimit(2)
    }
}
