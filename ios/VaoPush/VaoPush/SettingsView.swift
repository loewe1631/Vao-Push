import SwiftUI
import UserNotifications
import VaoPushCore

struct SettingsView: View {
    @Bindable var model: PrototypeModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(VaoL10n.preferenceKey, store: VaoL10n.preferences) private var language = "system"
    @State private var adding = false
    @State private var clearingSource: ContentSource?
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("BrandMark").resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vao Push").font(.title2.weight(.semibold))
                        Text(VaoL10n.text("消息与数据，各有去处。")).font(.caption).foregroundStyle(VaoTheme.secondary)
                    }
                }.padding(.vertical, 6)
            }
            Section {
                ForEach(model.connections) { connection in
                    NavigationLink {
                        ServerDetailView(model: model, connectionID: connection.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack").foregroundStyle(VaoTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(connection.name).font(.body.weight(.medium))
                                Text(serverStatus(connection, model: model)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Button { adding = true } label: { Label(VaoL10n.text("添加服务器"), systemImage: "plus") }
                    .accessibilityIdentifier("add-server")
            } header: { Text(VaoL10n.text("服务器")) } footer: {
                Text(VaoL10n.text("添加地址后自动注册并生成发送地址。可同时接收多台服务器的消息和卡片数据。"))
            }
            Section {
                NavigationLink {
                    Form {
                        LabeledContent(VaoL10n.text("系统通知权限"), value: model.notificationStatus)
                        LabeledContent(VaoL10n.text("推送连接"), value: VaoL10n.text(UserDefaults.standard.string(forKey: "apns-registration-status") ?? "正在连接"))
                        Button(VaoL10n.text("请求通知权限")) { Task { await model.requestNotifications() } }
                        Button(VaoL10n.text("前往系统设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                        Text(VaoL10n.text("通知权限由 iOS 管理。添加服务器后即可同步消息。允许通知后，还需服务器具备有效的苹果推送配置。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }.navigationTitle(VaoL10n.text("通知设置")).task { await model.refreshNotificationStatus() }
                } label: {
                    LabeledContent { Text(model.notificationStatus).foregroundStyle(.secondary) } label: { Label(VaoL10n.text("通知设置"), systemImage: "bell") }
                }
                NavigationLink {
                    Form {
                        ForEach(model.sources) { source in
                            Section(source.name) {
                                LabeledContent(VaoL10n.text("本地数据"), value: VaoL10n.text("{0} 份", String(describing: model.snapshots.filter { $0.source.owner == source.owner }.count)))
                                LabeledContent(VaoL10n.text("本地消息"), value: VaoL10n.text("{0} 条", String(describing: model.messages.filter { $0.source.owner == source.owner }.count)))
                            }
                        }
                        Button(VaoL10n.text("同步所有服务器")) {
                            Task { await model.syncAll() }
                        }
                        Text(VaoL10n.text("显示最近同步的内容。App 在前台时自动检查已连接服务器；失败时保留上次内容。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }.navigationTitle(VaoL10n.text("数据与同步"))
                } label: { Label(VaoL10n.text("数据与同步"), systemImage: "arrow.triangle.2.circlepath") }
            }
            Section {
                Picker(VaoL10n.text("语言"), selection: $language) {
                    Text(VaoL10n.text("跟随系统")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }.accessibilityIdentifier("interface-language")
                Picker(VaoL10n.text("外观"), selection: $appearance) {
                    Text(VaoL10n.text("跟随系统")).tag("system")
                    Text(VaoL10n.text("浅色")).tag("light")
                    Text(VaoL10n.text("深色")).tag("dark")
                }
                NavigationLink {
                    Form {
                        Section {
                            ForEach(model.sources) { source in
                                Button(VaoL10n.text("清理{0}的本地消息", String(describing: source.name)), role: .destructive) { clearingSource = source }
                            }
                        } footer: { Text(VaoL10n.text("仅删除本机消息记录，不影响服务器历史、数据快照与卡片设置。")) }
                    }.navigationTitle(VaoL10n.text("本地数据管理"))
                        .alert(VaoL10n.text("清理本地消息？"), isPresented: Binding(get: { clearingSource != nil }, set: { if !$0 { clearingSource = nil } })) {
                            Button(VaoL10n.text("取消"), role: .cancel) { clearingSource = nil }
                            Button(VaoL10n.text("清理"), role: .destructive) {
                                if let source = clearingSource { model.clearMessages(owner: source.owner) }
                                clearingSource = nil
                            }
                        } message: { Text(VaoL10n.text("仅清理“{0}”的本地消息；其他来源不受影响。", String(describing: clearingSource?.name ?? ""))) }
                } label: { Label(VaoL10n.text("本地数据管理"), systemImage: "internaldrive") }
                NavigationLink {
                    List {
                        Section(VaoL10n.text("两种接收方式")) {
                            Text(VaoL10n.text("消息：每个事件独立保存，并可显示系统通知。"))
                            Text(VaoL10n.text("桌面卡片：同一数据 ID 持续更新最新内容，保留你设置的名称与排版。"))
                        }
                        Section(VaoL10n.text("连接你的服务")) {
                    Text(VaoL10n.text("在设置中添加兼容 Vao Push 的 HTTP 或 HTTPS 服务。添加后自动注册本设备；消息和卡片都保留来源。"))
                            Text(VaoL10n.text("自动化工具、脚本和业务系统可调用服务接口；也可以通过该服务的 Web 控制台手动发送。"))
                            Text("POST /v1/push/{key}").font(.footnote.monospaced()).textSelection(.enabled)
                            Text("PUT /v1/state/{key}/{data_id}").font(.footnote.monospaced()).textSelection(.enabled)
                        }
                        Section(VaoL10n.text("多卡滑动切换")) {
                            Text(VaoL10n.text("添加多个相同尺寸的 Vao Push 小组件，分别选择行情、服务器信息等卡片，再拖叠成系统智能叠放，上下滑动切换。"))
                            Text(VaoL10n.text("叠放由系统管理，每个组件独立选择卡片；可以跨服务器组合。只想手动切换时，在编辑叠放中关闭智能轮换。"))
                        }
                        Section(VaoL10n.text("桌面更新")) { Text(VaoL10n.text("显示最近收到的数据及来源时间。更新由 iOS 调度，不保证每分钟刷新。")) }
                    }.navigationTitle(VaoL10n.text("接入指南"))
                } label: { Label(VaoL10n.text("接入指南"), systemImage: "book") }
            }
            Section {
                NavigationLink { AboutView(version: appVersion) } label: {
                    Label(VaoL10n.text("关于"), systemImage: "info.circle")
                }.accessibilityIdentifier("settings-about")
                NavigationLink { PrivacyDetailsView() } label: { Label(VaoL10n.text("数据与隐私"), systemImage: "hand.raised") }
                LabeledContent(VaoL10n.text("版本"), value: appVersion)
            } footer: { Text(VaoL10n.text("消息推送需服务器配置 Apple 推送身份；桌面刷新由 iOS 调度。")) }
        }.scrollContentBackground(.hidden).background(VaoTheme.background).navigationTitle(VaoL10n.text("设置"))
            .sheet(isPresented: $adding) { AddServerView(model: model) }
    }
}

@MainActor private func serverStatus(_ connection: ServerConnection, model: PrototypeModel) -> String {
    if !connection.isEnabled { return VaoL10n.text("已停用 · 本地内容保留") }
    if connection.isDemo { return VaoL10n.text("本地模拟 · 不连接网络") }
    if model.registering.contains(connection.id) { return VaoL10n.text("正在连接") }
    if model.inspecting.contains(connection.id) { return VaoL10n.text("检测中") }
    if model.connectionErrors[connection.id] != nil { return VaoL10n.text("连接需要处理") }
    if model.syncing.contains(connection.id) { return VaoL10n.text("同步中") }
    if connection.bindingID != nil { return connection.syncedAt == nil ? VaoL10n.text("已连接 · 等待同步") : VaoL10n.text("已连接 · 已同步") }
    if connection.checkedAt != nil { return VaoL10n.text("地址已确认 · 待连接") }
    return VaoL10n.text("地址已保存 · 待连接")
}

private struct AddServerView: View {
    let model: PrototypeModel
    @State private var name = ""
    @State private var address = ""
    @State private var deviceName = ""
    @State private var error: String?
    @State private var connecting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(VaoL10n.text("服务器")) {
                    TextField(VaoL10n.text("名称（可选）"), text: $name).accessibilityIdentifier("server-name")
                    TextField("http://203.0.113.10:8188", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("server-address")
                }
                if address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                    Section { Text(VaoL10n.text("HTTP 连接不会加密传输，请仅连接你信任的服务器。"))
                        .font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    TextField(VaoL10n.text("例如：工作手机、家里的 iPad"), text: $deviceName)
                        .autocorrectionDisabled().accessibilityIdentifier("registration-device-name")
                } header: { Text(VaoL10n.text("此设备的名称（必填）")) } footer: {
                    Text(VaoL10n.text("用于在 Web 中辨认这个接收端，最多40字；与服务器名称分别设置。"))
                }
                Section { Text(VaoL10n.text("填写地址和设备名称后自动连接并获得发送地址，无需登录或配对码。"))
                    .font(.footnote).foregroundStyle(.secondary) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(connecting ? VaoL10n.text("连接中…") : VaoL10n.text("添加并连接")) {
                        connecting = true
                        Task {
                            do {
                                let id = try model.addServer(name: name, address: address, deviceName: deviceName)
                                await model.connectServer(id: id)
                                if let reason = model.connectionErrors[id] { model.error = VaoL10n.text("地址已保存，连接未完成：") + reason }
                                dismiss()
                            } catch { self.error = VaoL10n.text("无法添加服务器：") + error.localizedDescription }
                            connecting = false
                        }
                    }.disabled(connecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (try? ServerConnection.normalizedDeviceName(deviceName)) == nil)
                        .accessibilityIdentifier("save-server")
                }
            }.navigationTitle(VaoL10n.text("添加服务器")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(VaoL10n.text("取消")) { dismiss() }.disabled(connecting) }
                }
        }.interactiveDismissDisabled(connecting)
    }
}

private struct ServerDetailView: View {
    let model: PrototypeModel
    let connectionID: String
    @State private var removing = false
    @State private var name = ""
    @State private var copied = false
    @State private var deviceName = ""
    @State private var renaming = false
    @State private var removalInProgress = false
    @State private var remoteRemovalError: String?
    @State private var localRemovalError: String?
    @Environment(\.dismiss) private var dismiss
    private var connection: ServerConnection? { model.connections.first { $0.id == connectionID } }

    var body: some View {
        Form {
            if let connection {
                Section(VaoL10n.text("服务器")) {
                    TextField(VaoL10n.text("显示名称"), text: $name)
                    Button(VaoL10n.text("保存名称")) { update { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == connection.name)
                    Text(connection.baseURL.absoluteString).font(.footnote).textSelection(.enabled)
                    Toggle(VaoL10n.text("启用此服务器"), isOn: Binding(get: { connection.isEnabled }, set: { value in Task { await model.setServerEnabled(connection, enabled: value) } }))
                        .accessibilityIdentifier("enable-server")
                    Text(serverStatus(connection, model: model)).font(.footnote).foregroundStyle(.secondary)
                }
                if !connection.isDemo {
                    Section {
                        TextField(VaoL10n.text("此设备的名称"), text: $deviceName)
                            .autocorrectionDisabled().accessibilityIdentifier("bound-device-name")
                        Button(renaming ? VaoL10n.text("保存中…") : VaoL10n.text("保存设备名称")) {
                            renaming = true
                            Task { await model.renameDevice(id: connectionID, name: deviceName); renaming = false }
                        }.disabled(renaming || model.registering.contains(connectionID) || deviceName == connection.deviceName || (try? ServerConnection.normalizedDeviceName(deviceName)) == nil)
                            .accessibilityIdentifier("save-device-name")
                        if let binding = connection.bindingID {
                            LabeledContent(VaoL10n.text("设备标识"), value: binding).font(.caption).textSelection(.enabled)
                        }
                    } header: { Text(VaoL10n.text("此设备在服务器上的名称")) } footer: {
                        Text(VaoL10n.text("Web 使用这个名称辨认接收端。修改名称保留原有绑定、消息、卡片和默认接收列表。"))
                    }
                    Section {
                        Button(model.inspecting.contains(connectionID) ? VaoL10n.text("检测中…") : VaoL10n.text("检测服务器")) {
                            Task { await model.inspectServer(id: connectionID) }
                        }.disabled(model.inspecting.contains(connectionID) || !connection.isEnabled)
                        if connection.bindingID == nil {
                            Button(model.registering.contains(connectionID) ? VaoL10n.text("连接中…") : VaoL10n.text("连接本设备")) {
                                Task { await model.connectServer(id: connectionID) }
                            }.disabled(model.registering.contains(connectionID) || !connection.isEnabled || connection.deviceName == nil)
                        } else {
                            Button(model.syncing.contains(connectionID) ? VaoL10n.text("同步中…") : VaoL10n.text("同步消息与数据")) {
                                Task { await model.syncServer(id: connectionID) }
                            }.disabled(model.syncing.contains(connectionID) || !connection.isEnabled)
                            if let synced = connection.syncedAt { LabeledContent(VaoL10n.text("最近同步"), value: synced).font(.caption) }
                        }
                        if let message = model.connectionErrors[connectionID] { Text(message).font(.footnote).foregroundStyle(.orange) }
                        if let checked = connection.checkedAt { LabeledContent(VaoL10n.text("最近检测"), value: checked).font(.caption) }
                    } footer: { Text(VaoL10n.text("连接后自动生成本设备的发送地址。网络失败时可重试，更换地址请添加新服务器。")) }
                }
                if !connection.isDemo, let key = model.sendKeys[connectionID] {
                    Section {
                        Button { copy(connection.baseURL.appendingPathComponent("v1/push/" + key).absoluteString) } label: {
                            Label(VaoL10n.text("复制消息发送地址"), systemImage: "doc.on.doc")
                        }.accessibilityIdentifier("copy-message-url")
                        Text(VaoL10n.text("数据卡片的上报地址在Web卡片工作台中配置和复制。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        DisclosureGroup(VaoL10n.text("兼容接口与高级信息")) {
                            Button { copy(connection.baseURL.appendingPathComponent("v1/state/" + key).absoluteString + "/{data_id}") } label: {
                                Label(VaoL10n.text("复制兼容数据地址"), systemImage: "doc.on.doc")
                            }.accessibilityIdentifier("copy-state-url")
                            Text(VaoL10n.text("兼容数据地址用于已有本机数据卡片。新功能卡片请在Web设计后通过订阅码导入。"))
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup(VaoL10n.text("查看发送 Key")) { Text(key).font(.caption.monospaced()).textSelection(.enabled).privacySensitive() }
                        }
                        if copied { Text(VaoL10n.text("已复制")).font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text(VaoL10n.text("发送到这台设备")) } footer: {
                        Text(VaoL10n.text("消息地址使用POST提交。发送地址包含访问凭据，请妥善保管。"))
                    }
                }
                Section {
                    Button(removalInProgress ? VaoL10n.text("正在移除…") : VaoL10n.text("移除服务器及其本地数据"), role: .destructive) { removing = true }
                        .disabled(model.registering.contains(connectionID) || removalInProgress)
                        .accessibilityIdentifier("remove-server")
                } footer: { Text(VaoL10n.text("先尝试解绑服务器，再移除本机数据。服务器无法连接时，可选择强制删除本地配置。")) }
            }
        }.navigationTitle(VaoL10n.text("服务器详情")).navigationBarTitleDisplayMode(.inline)
            .onAppear { name = connection?.name ?? ""; deviceName = connection?.deviceName ?? "" }
            .onChange(of: connection?.deviceName) { old, updated in
                if deviceName.isEmpty || deviceName == old { deviceName = updated ?? "" }
            }
            .task { if connection?.bindingID != nil { await model.syncServer(id: connectionID) } }
            .confirmationDialog(VaoL10n.text("移除这台服务器及其本地数据？"), isPresented: $removing, titleVisibility: .visible) {
                Button(VaoL10n.text("移除服务器及本地数据"), role: .destructive) {
                    removeServer()
                }
                .accessibilityIdentifier("confirm-remove-server")
            } message: { Text(VaoL10n.text("将请求服务器解绑，并删除此来源的本机卡片、消息、缓存及凭据。其他服务器不受影响。")) }
            .alert(VaoL10n.text("远端解绑未完成"), isPresented: Binding(get: { remoteRemovalError != nil }, set: { if !$0 { remoteRemovalError = nil } })) {
                Button(VaoL10n.text("重试")) { remoteRemovalError = nil; removeServer() }
                Button(VaoL10n.text("强制删除本地配置"), role: .destructive) { remoteRemovalError = nil; removeServer(localOnly: true) }
                    .accessibilityIdentifier("force-remove-local-server")
                Button(VaoL10n.text("取消"), role: .cancel) { remoteRemovalError = nil }
            } message: {
                Text(VaoL10n.text("服务器无法连接或未确认解绑。本机资料尚未删除。强制删除只清理此来源的本机数据；远端可能仍保留设备绑定并继续发送通知。") + "\n\n" + (remoteRemovalError ?? ""))
            }
            .alert(VaoL10n.text("本机数据未完成移除"), isPresented: Binding(get: { localRemovalError != nil }, set: { if !$0 { localRemovalError = nil } })) {
                Button(VaoL10n.text("知道了")) { localRemovalError = nil }
            } message: { Text(localRemovalError ?? "") }
    }

    private func removeServer(localOnly: Bool = false) {
        guard let connection, !removalInProgress else { return }
        removalInProgress = true
        Task {
            let result = await model.removeServer(connection, localOnly: localOnly)
            removalInProgress = false
            switch result {
            case .removed: dismiss()
            case .remoteUnconfirmed(let reason): remoteRemovalError = reason
            case .localFailure(let reason): localRemovalError = reason
            }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
    }

    private func update(_ mutation: (inout ServerConnection) -> Void) {
        guard var connection else { return }
        mutation(&connection)
        do { try model.updateServer(connection) } catch { model.error = String(describing: error) }
    }
}

private struct PrivacyDetailsView: View {
    var body: some View {
        List {
            Section(VaoL10n.text("消息与卡片")) {
                Text(VaoL10n.text("消息和卡片通过你添加的服务器同步，系统通知通过Apple推送服务投递。内容会保存在所选服务器及本机，以便查看历史和更新桌面。"))
            }
            Section(VaoL10n.text("连接信息")) {
                Text(VaoL10n.text("设备名称、设备标识及推送标识用于绑定与投递。连接凭证保存在系统钥匙串中。App没有广告或跨应用跟踪功能。"))
            }
            Section(VaoL10n.text("管理数据")) {
                Text(VaoL10n.text("可在“本地数据管理”清理本机消息。移除服务器可解绑并删除对应本机卡片、消息和凭证；仅本机清理不会停止远程投递。"))
                Text(VaoL10n.text("服务器上的数据保留和删除由该服务器管理员管理。使用第三方服务器前，请查看其数据政策。"))
            }
        }.navigationTitle(VaoL10n.text("数据与隐私")).navigationBarTitleDisplayMode(.inline)
    }
}
