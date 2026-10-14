import SwiftUI

struct LiveDirectoryView: View {
    @State private var platforms: [RemotePlatform] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("发现正在直播").font(.title2.bold())
                        Text(platforms.isEmpty ? "加载平台与在线房间" : "\(platforms.count) 个平台 · 点击查看在线房间").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if loading { ProgressView() }
                }.padding(.vertical, 10)
                if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await load() } }.buttonStyle(.bordered)
                    }.accessibilityIdentifier("directoryError")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(platforms.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { platform in
                        NavigationLink { RemoteRoomsView(platform: platform) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                RemoteCover(url: platform.image, height: 105)
                                Text(platform.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                                Label("\(platform.online) 个在线房间", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption2).foregroundStyle(Theme.accent)
                            }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("platform_\(platform.id)")
                    }
                }
                if !loading && platforms.isEmpty && error == nil {
                    QuietEmpty(symbol: "dot.radiowaves.left.and.right", title: "暂无在线平台", detail: "稍后下拉刷新，查看最新直播。")
                }
            }.padding(20).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .background(Theme.background).navigationTitle("直播")
        .searchable(text: $search, prompt: "搜索直播平台")
        .refreshable { await load() }
        .toolbar { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新平台").disabled(loading) }
        .task { if platforms.isEmpty { await load() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { platforms = try await LiveAPI.shared.platforms() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct RemoteRoomsView: View {
    let platform: RemotePlatform
    @EnvironmentObject private var router: PlayerRouter
    @State private var rooms: [RemoteRoom] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("\(rooms.count) 个在线房间").font(.subheadline).foregroundStyle(Theme.muted); Spacer(); if loading { ProgressView() } }
                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("重新加载") { Task { await load() } }.buttonStyle(.bordered)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(rooms.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { room in
                        Button {
                            router.open(room.item(platform: platform, fallback: LiveAPIConfiguration.production.bases[0]))
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                RemoteCover(url: room.image, height: 180)
                                Text(room.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Label("进入直播", systemImage: "play.fill").font(.caption2).foregroundStyle(Theme.accent)
                            }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("room_\(room.id)")
                    }
                }
                if !loading && rooms.isEmpty && error == nil { QuietEmpty(symbol: "video.slash", title: "暂无在线房间", detail: "稍后刷新，或选择其他平台。") }
            }.padding(20).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .background(Theme.background).navigationTitle(platform.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索房间")
        .refreshable { await load() }
        .task { if rooms.isEmpty { await load() } }
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { rooms = try await LiveAPI.shared.rooms(platformID: platform.id) }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct RemoteCover: View {
    let url: URL?
    let height: CGFloat
    var body: some View {
        GeometryReader { frame in
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                ZStack { Theme.background; Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(Theme.accent.opacity(0.6)) }
            }.frame(width: frame.size.width, height: height).clipped()
        }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
    }
}

struct RemotePlaybackScreen: View {
    let item: LiveItem
    @Environment(\.dismiss) private var dismiss
    @State private var resolved: LiveItem?
    @State private var error: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let resolved { PlayerScreen(item: resolved) }
            else {
                VStack(spacing: 18) {
                    if let error {
                        QuietEmpty(symbol: "play.slash", title: "暂时无法进入直播", detail: error)
                        Button("重新连接") { attempt += 1 }.buttonStyle(.borderedProminent)
                    } else { ProgressView(); Text("正在连接直播…").foregroundStyle(Theme.muted) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
                    .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
            }
        }.task(id: attempt) {
            error = nil
            do { resolved = try await LiveAPI.shared.playback(item) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
