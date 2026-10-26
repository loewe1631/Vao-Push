import SwiftUI
import VaoPushCore

struct CardEditor: View {
    let model: PrototypeModel
    let snapshot: StateSnapshot
    let source: ContentSource
    let isNew: Bool
    let onFinish: (() -> Void)?
    @State private var draft: CardConfiguration
    @State private var previewSize = 1
    @State private var mode: CardDisplayMode = .summary
    @State private var error: String?
    @State private var editMode: EditMode = .inactive
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(model: PrototypeModel, original: CardConfiguration, snapshot: StateSnapshot, source: ContentSource,
         isNew: Bool = false, onFinish: (() -> Void)? = nil) {
        self.model = model; self.snapshot = snapshot
        self.source = source
        self.isNew = isNew; self.onFinish = onFinish
        _draft = State(initialValue: original)
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the draft above this layout switch so a fold/resize cannot reset edits.
            if geometry.size.width >= 760 && !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(VaoL10n.text("实时预览 · {0}", String(describing: source.name))).font(.headline)
                            preview
                        }.padding(24)
                    }
                    .frame(width: min(geometry.size.width * 0.42, 440))
                    Divider()
                    Form { settingsSections }
                }
            } else {
                Form {
                    Section(VaoL10n.text("实时预览 · {0}", String(describing: source.name))) { preview }
                    settingsSections
                }
            }
        }
        .onAppear { mergeFields() }
        .onChange(of: draft.itemID) { _, _ in mergeFields(); draft.seriesKey = draft.selectedSeries(in: snapshot.state).keys.sorted().first }
        .navigationTitle(isNew ? VaoL10n.text("新建卡片") : VaoL10n.text("编辑卡片"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .environment(\.editMode, $editMode)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button(VaoL10n.text("取消")) { finish() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if draft.remote == nil {
                Button(editMode.isEditing ? VaoL10n.text("完成排序") : VaoL10n.text("排序")) {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(VaoL10n.text("保存")) {
                    save()
                }.bold().accessibilityIdentifier("save-card")
            }
        }
        .alert(VaoL10n.text("无法保存"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(VaoL10n.text("知道了")) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }

    private func save() {
        if let remote = draft.remote {
            draft.remote?.adjustments.nodes = remote.adjustments.nodes.filter { $0.value != NodeAdjustment() }
            draft.remote?.adjustments.name = draft.name == remote.design.name ? nil : draft.name
            let theme = draft.theme?.rawValue ?? "system"
            draft.remote?.adjustments.theme = theme == (remote.design.theme ?? "system") ? nil : theme
        }
        do { try model.save(draft, source: source); finish() }
        catch { self.error = String(describing: error) }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(VaoL10n.text("预览尺寸"), selection: $previewSize) {
                Text(VaoL10n.text("小")).tag(0); Text(VaoL10n.text("中")).tag(1); Text(VaoL10n.text("大")).tag(2); Text(VaoL10n.text("超大 · iPad")).tag(3)
            }.pickerStyle(.segmented)
            PrototypeCardView(card: draft, snapshot: snapshot, mode: mode, compact: previewSize < 2, expanded: previewSize > 1, sourceName: source.name, isDemo: source.isDemo, fieldLimit: [2,4,12,20][previewSize])
                .frame(minHeight: previewSize == 0 ? 145 : previewSize == 1 ? 165 : 290).padding(.vertical, 8)
            if draft.fields.filter(\.visible).count > [2,4,12,20][previewSize] {
                Text(VaoL10n.text("此尺寸只显示前{0}项；可调整顺序或选择更大尺寸。", String(describing: [2,4,12,20][previewSize]))).font(.caption).foregroundStyle(.secondary)
            }
            if draft.seriesKey != nil {
                Button(mode == .summary ? VaoL10n.text("预览图表") : VaoL10n.text("返回概览")) {
                    mode = mode == .summary ? .chart : .summary
                }
            }
        }
    }

    private func mergeFields() {
        let keys = draft.selectedFields(in: snapshot.state).keys.sorted()
        let existing = Set(draft.fields.map(\.key))
        draft.fields += keys.filter { !existing.contains($0) }.map { FieldBinding(key: $0, visible: false) }
    }

    @ViewBuilder private var settingsSections: some View {
        if let remote = draft.remote {
            Section(VaoL10n.text("Web订阅卡片 · 第{0}版", String(describing: remote.revision))) {
                TextField(VaoL10n.text("卡片名称"), text: $draft.name).accessibilityIdentifier("card-name")
                Picker(VaoL10n.text("本机外观"), selection: Binding(get: { draft.theme ?? .system }, set: { draft.theme = $0 })) {
                    Text(VaoL10n.text("跟随系统")).tag(CardConfiguration.Theme.system)
                    Text(VaoL10n.text("浅色")).tag(CardConfiguration.Theme.light)
                    Text(VaoL10n.text("深色")).tag(CardConfiguration.Theme.dark)
                }
                Button(VaoL10n.text("恢复全部跟随Web设计")) {
                    draft.remote?.adjustments = CardAdjustments(); draft.name = remote.design.name
                    draft.theme = CardConfiguration.Theme(rawValue: remote.design.theme ?? "system")
                }
                if let issue = remote.issue { Text(VaoL10n.text(issue)).foregroundStyle(.orange) }
                Text(VaoL10n.text("本机微调不影响Web或其他设备；未微调的内容继续跟随已发布设计。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(remote.design.nodes.filter { ["text", "number", "badge", "chart"].contains($0.type) }) { node in
                Section(node.label ?? node.bind ?? node.text ?? node.id) {
                    Toggle(VaoL10n.text("显示组件"), isOn: Binding(get: { draft.remote?.adjustments.nodes[node.id]?.hidden != true }, set: { value in
                        var adjustment = draft.remote?.adjustments.nodes[node.id] ?? NodeAdjustment(); adjustment.hidden = !value
                        draft.remote?.adjustments.nodes[node.id] = adjustment
                    }))
                    if node.type != "chart" {
                    TextField(VaoL10n.text("本机显示名称（留空跟随Web）"), text: Binding(get: { draft.remote?.adjustments.nodes[node.id]?.label ?? "" }, set: { value in
                        var adjustment = draft.remote?.adjustments.nodes[node.id] ?? NodeAdjustment(); adjustment.label = value.isEmpty ? nil : value
                        draft.remote?.adjustments.nodes[node.id] = adjustment
                    })).accessibilityIdentifier("web-alias-" + node.id)
                    if node.type == "number" || node.type == "badge" {
                    Picker(VaoL10n.text("小数位"), selection: adjustment(node.id, \.decimals)) {
                        Text(VaoL10n.text("跟随Web")).tag(Int?.none)
                        ForEach(0...18, id: \.self) { Text(VaoL10n.text("{0}位", String(describing: $0))).tag(Optional($0)) }
                    }
                    }
                    Picker(VaoL10n.text("字号"), selection: adjustment(node.id, \.fontSize)) {
                        Text(VaoL10n.text("跟随Web")).tag(Int?.none)
                        ForEach([10,12,14,16,18,20,24,28,32], id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }
                    }
                    Button(VaoL10n.text("此组件恢复跟随Web")) { draft.remote?.adjustments.nodes.removeValue(forKey: node.id) }
                }
            }
            Section { Button(VaoL10n.text("保存微调")) { save() }.accessibilityIdentifier("save-web-adjustments") }
        } else { localSettingsSections }
    }

    private func adjustment(_ id: String, _ path: WritableKeyPath<NodeAdjustment, Int?>) -> Binding<Int?> {
        Binding(get: { draft.remote?.adjustments.nodes[id]?[keyPath: path] }, set: { value in
            var adjustment = draft.remote?.adjustments.nodes[id] ?? NodeAdjustment(); adjustment[keyPath: path] = value
            draft.remote?.adjustments.nodes[id] = adjustment
        })
    }

    @ViewBuilder private var localSettingsSections: some View {
        Section(VaoL10n.text("卡片")) {
            TextField(VaoL10n.text("卡片名称"), text: $draft.name).accessibilityIdentifier("card-name")
            Picker(VaoL10n.text("样式"), selection: $draft.template) {
                Text(VaoL10n.text("重点指标")).tag(CardConfiguration.Template.metric)
                Text(VaoL10n.text("信息列表")).tag(CardConfiguration.Template.list)
                Text(VaoL10n.text("历史图表")).tag(CardConfiguration.Template.chart)
            }
            Picker(VaoL10n.text("外观"), selection: Binding(get: { draft.theme ?? .system }, set: { draft.theme = $0 })) {
                Text(VaoL10n.text("跟随系统")).tag(CardConfiguration.Theme.system)
                Text(VaoL10n.text("浅色")).tag(CardConfiguration.Theme.light)
                Text(VaoL10n.text("深色")).tag(CardConfiguration.Theme.dark)
            }
            Toggle(VaoL10n.text("显示单位"), isOn: Binding(get: { draft.showUnits ?? true }, set: { draft.showUnits = $0 }))
            if let items = snapshot.state.items, !items.isEmpty {
                Picker(VaoL10n.text("展示内容"), selection: $draft.itemID) {
                    Text(VaoL10n.text("顶层字段")).tag(String?.none)
                    ForEach(items, id: \.itemID) { item in Text(item.itemID).tag(Optional(item.itemID)) }
                    if let id = draft.itemID, !items.contains(where: { $0.itemID == id }) { Text(VaoL10n.text("{0} · 暂不可用", String(describing: id))).tag(Optional(id)) }
                }
            }
            let series = draft.selectedSeries(in: snapshot.state)
            if !series.isEmpty {
                Picker(VaoL10n.text("图表数据"), selection: $draft.seriesKey) {
                    Text(VaoL10n.text("不使用")).tag(String?.none)
                    ForEach(series.keys.sorted(), id: \.self) { key in
                        Text(series[key]?.label ?? key).tag(Optional(key))
                    }
                }
            }
        }
        Section {
            ForEach($draft.fields) { $field in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $field.visible) {
                        Text(draft.selectedFields(in: snapshot.state)[field.key]?.label ?? field.key).font(.headline)
                    }
                    TextField(VaoL10n.text("显示名称"), text: Binding(get: { field.alias ?? "" },
                        set: { field.alias = $0.isEmpty ? nil : $0 }))
                        .accessibilityIdentifier("alias-" + field.key)
                    if let type = draft.selectedFields(in: snapshot.state)[field.key]?.type,
                       [.decimal, .integer, .percent].contains(type) {
                        Picker(VaoL10n.text("小数位"), selection: $field.decimals) {
                            Text(VaoL10n.text("跟随原值")).tag(Int?.none)
                            ForEach(0...18, id: \.self) { Text(VaoL10n.text("{0} 位", String(describing: $0))).tag(Optional($0)) }
                        }
                    }
                }.padding(.vertical, 4)
            }
            .onMove { source, destination in draft.fields.move(fromOffsets: source, toOffset: destination) }
        } header: { Text(VaoL10n.text("显示字段")) } footer: {
            Text(VaoL10n.text("关闭字段可隐藏；留空名称将使用来源名称。点右上角“排序”可拖动调整。数据更新不会重置这些设置。"))
        }
        if isNew {
            Section {
                Button(VaoL10n.text("保存卡片")) { save() }.accessibilityIdentifier("save-new-card")
                Button(VaoL10n.text("取消"), role: .cancel) { finish() }
            }
        }
    }
}
