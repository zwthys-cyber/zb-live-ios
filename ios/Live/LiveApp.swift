import SwiftUI

@MainActor
final class PlayerRouter: ObservableObject {
    @Published var selected: LiveItem?
    func open(_ item: LiveItem) { selected = item }
}

@main
struct LiveApp: App {
    @StateObject private var library = LibraryStore(ephemeral: ProcessInfo.processInfo.arguments.contains("--ui-testing"))
    @StateObject private var router = PlayerRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(router)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: PlayerRouter

    var body: some View {
        TabView {
            NavigationStack { LiveDirectoryView() }
                .tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack { HomeView() }
                .tabItem { Label("频道", systemImage: "play.rectangle.fill") }
            NavigationStack { FavoritesView() }
                .tabItem { Label("收藏", systemImage: "heart.fill") }
            NavigationStack { SettingsView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .fullScreenCover(item: $router.selected) { item in
            NavigationStack {
                if item.roomID != nil { RemotePlaybackScreen(item: item) }
                else if item.kind == .web { BrowserScreen(item: item) }
                else { PlayerScreen(item: item) }
            }
            .environmentObject(library)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
        .alert("提示", isPresented: Binding(get: { library.notice != nil }, set: { if !$0 { library.notice = nil } })) {
            Button("知道了") { library.notice = nil }
        } message: { Text(library.notice ?? "") }
    }
}

enum Theme {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.09)
    static let surface = Color(red: 0.075, green: 0.105, blue: 0.15)
    static let accent = Color(red: 0.30, green: 0.91, blue: 0.74)
    static let muted = Color(red: 0.52, green: 0.61, blue: 0.70)
    static let palette: [Color] = [.mint, .cyan, .indigo, .orange, .purple, .pink, .blue]
}

struct SectionCaption: View {
    let title: String
    var detail = ""
    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(Theme.muted) }
        }
        .padding(.top, 12)
        .padding(.bottom, 2)
    }
}

struct ItemRow: View {
    let item: LiveItem
    var trailing = "chevron.right"
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind == .web ? "globe.asia.australia.fill" : "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 46, height: 46)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(item.group.isEmpty ? item.kind.label : item.group + " · " + item.kind.label)
                    .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: trailing).font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
    }
}

struct QuietEmpty: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent).frame(width: 76, height: 76)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 38).padding(.horizontal, 24)
    }
}
