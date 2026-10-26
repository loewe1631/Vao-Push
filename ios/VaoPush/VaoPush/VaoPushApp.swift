import SwiftUI
import VaoPushCore
import os
import WidgetKit

@main
struct VaoPushApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @State private var model: PrototypeModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(VaoL10n.preferenceKey, store: VaoL10n.preferences) private var language = "system"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        Logger(subsystem: "app.vaovao.push", category: "Startup").notice("app_model_begin")
        #endif
        _model = State(initialValue: PrototypeModel())
        #if DEBUG
        Logger(subsystem: "app.vaovao.push", category: "Startup").notice("app_model_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000, privacy: .public)")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isReady {
                    ContentView(model: model)
                        .transition(.opacity)
                        .onAppear { Logger(subsystem: "app.vaovao.push", category: "Startup").notice("main_view_appeared") }
                } else {
                    BrandStartupView(error: model.startupError) { Task { await model.start() } }
                        .transition(.opacity)
                        .onAppear { Logger(subsystem: "app.vaovao.push", category: "Startup").notice("startup_view_appeared") }
                }
            }.tint(VaoTheme.accent)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isReady)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .environment(\.locale, Locale(identifier: VaoL10n.identifier(preference: language)))
                .onChange(of: language) { _, _ in
                    model.error = nil
                    try? model.reload()
                    Task { await model.refreshNotificationStatus() }
                    WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
                }
                .task { await model.start() }
        }
    }
}

/// Matches the system launch screen so loading does not move the brand mark.
private struct BrandStartupView: View {
    let error: String?
    var retry: () -> Void
    @State private var showProgress = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
            VStack(spacing: 18) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("Vao Push").font(.system(size: 24, weight: .semibold)).frame(height: 29)
            }.offset(y: -3.5)
            VStack(spacing: 14) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(VaoL10n.text("重试"), action: retry).buttonStyle(.borderedProminent)
                } else if showProgress {
                    ProgressView(VaoL10n.text("正在准备…")).font(.footnote)
                }
            }.frame(maxWidth: 360).padding(.horizontal, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 60)
        }.ignoresSafeArea()
            .task {
                do { try await Task.sleep(for: .milliseconds(600)); showProgress = true }
                catch { /* A quick launch needs no loading indicator. */ }
            }
    }
}
