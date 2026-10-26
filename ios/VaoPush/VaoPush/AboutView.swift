import SwiftUI
import VaoPushCore

struct AboutView: View {
    let version: String

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("BrandMark")
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text("Vao Push").font(.title2.weight(.semibold))
                    Text(version).font(.subheadline).foregroundStyle(VaoTheme.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            }

            Section {
                Link(destination: URL(string: "https://push.vaovao.app")!) {
                    linkRow(VaoL10n.text("官网"), address: "push.vaovao.app") {
                        Image(systemName: "globe")
                            .font(.system(size: 24))
                    }
                }
                .accessibilityIdentifier("about-website-link")

                Link(destination: URL(string: "https://github.com/loewe1631/Vao-Push")!) {
                    linkRow("GitHub", address: "github.com/loewe1631/Vao-Push") {
                        Image("GitHubMark")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                }
                .accessibilityIdentifier("about-github-link")
            } header: {
                Text(VaoL10n.text("了解部署服务端以及更多详情，请访问官网和 GitHub。"))
                    .textCase(nil)
                    .font(.subheadline)
                    .padding(.bottom, 8)
            }
            .listRowBackground(VaoTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(VaoTheme.background)
        .navigationTitle(VaoL10n.text("关于"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func linkRow<Icon: View>(_ title: String, address: String,
                                     @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 14) {
            icon()
                .foregroundStyle(VaoTheme.accent)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(VaoTheme.text)
                Text(address).font(.caption).foregroundStyle(VaoTheme.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(VaoTheme.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
    }
}
