import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var showImport = false
    @State private var clearData = false
    @State private var message: String?
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 32)).foregroundStyle(Theme.accent)
                        .frame(width: 64, height: 64).background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("直播").font(.title2.bold())
                        Text("你的平台、频道与收藏").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
            }
            Section("我的内容") {
                NavigationLink { HistoryView() } label: { Label("观看记录", systemImage: "clock.arrow.circlepath") }
                NavigationLink { SubscriptionsView() } label: { Label("频道订阅", systemImage: "rectangle.stack") }
                Button { showImport = true } label: { Label("导入频道", systemImage: "square.and.arrow.down") }
            }
            Section {
                Toggle("视频后台继续播放", isOn: Binding(get: { library.backgroundAudio }, set: { library.setBackgroundAudio($0) }))
            } header: { Text("播放") } footer: {
                Text("用于系统播放器打开的视频。网页后台播放取决于网站；画中画和投屏由播放器与媒体本身决定。")
            }
            Section {
                Button { clearData = true } label: { Label(clearing ? "正在清理…" : "清除网页缓存与登录", systemImage: "eraser") }.disabled(clearing)
                NavigationLink { AboutView() } label: { Label("关于与使用说明", systemImage: "info.circle") }.accessibilityIdentifier("aboutLink")
            }
            Section {
                Text("收藏与观看记录保存在本机。应用未集成广告、统计或 Android 加固组件。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("我的")
        .sheet(isPresented: $showImport) { ImportSheet() }
        .confirmationDialog("清除网页缓存和所有平台的登录状态？", isPresented: $clearData, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                clearing = true
                WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    Task { @MainActor in clearing = false; message = "网页缓存与登录状态已清除。" }
                }
            }
        }
        .alert("提示", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了") { message = nil }
        } message: { Text(message ?? "") }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: PlayerRouter
    @State private var confirmClear = false
    var body: some View {
        Group {
            if library.history.isEmpty { QuietEmpty(symbol: "clock", title: "还没有观看记录", detail: "成功打开的网页和视频会显示在这里。") }
            else {
                List(library.history) { record in
                    Button { router.open(record.item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ItemRow(item: record.item)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary).padding(.leading, 16)
                        }
                    }
                    .buttonStyle(.plain).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
        .navigationTitle("观看记录")
        .toolbar { if !library.history.isEmpty { Button("清空") { confirmClear = true } } }
        .confirmationDialog("清空观看记录？", isPresented: $confirmClear, titleVisibility: .visible) { Button("清空", role: .destructive) { library.clearHistory() } }
    }
}

struct SubscriptionsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var importing = false
    @State private var refreshing: String?
    @State private var result: String?
    @State private var clear = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Button { importing = true } label: { Label("添加订阅 / 导入文件", systemImage: "plus.circle.fill") }
                LabeledContent("已保存频道", value: "\(library.channels.count)")
            }
            if !library.subscriptions.isEmpty {
                Section("订阅地址") {
                    ForEach(library.subscriptions) { source in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(source.name).font(.headline)
                            Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(source.updated.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if refreshing == source.id { ProgressView() }
                                else {
                                    Button("刷新") { refresh(source) }.disabled(refreshing != nil)
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }.padding(.vertical, 5)
                        .swipeActions { Button("删除", role: .destructive) { library.removeSubscription(source) }.disabled(refreshing != nil) }
                    }
                }
            }
            if !library.channels.isEmpty {
                Section { Button("清空频道与订阅", role: .destructive) { clear = true } }
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background).navigationTitle("频道订阅")
        .sheet(isPresented: $importing) { ImportSheet() }
        .onDisappear { task?.cancel() }
        .confirmationDialog("清空所有已导入频道与订阅？收藏会保留。", isPresented: $clear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { library.clearChannels() }
        }
        .alert("订阅更新", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("知道了") { result = nil }
        } message: { Text(result ?? "") }
    }

    private func refresh(_ source: Subscription) {
        refreshing = source.id
        task = Task { @MainActor in
            defer { refreshing = nil }
            do {
                let items = try await PlaylistFetcher.load(source.url)
                guard !Task.isCancelled else { return }
                let count = try library.importItems(items, subscriptionURL: source.url)
                result = "已读取并合并 \(count) 个频道。"
            } catch { if !Task.isCancelled { result = error.localizedDescription } }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("直播 · 1.1") {
                Text("为 iOS 17.0 及以上系统重新编写的直播工具。")
                Text("直播页连接原服务，读取在线平台、房间和播放线路。频道页的平台入口在内置浏览器中打开网站。可在网页内登录、观看和收藏当前页面，也可用右上角菜单在 Safari 中打开。")
                Text("视频会尽量使用最高清晰度。多码率清单只保留最高一档；第一条地址低于 1080p 时，会再试同一站点里更高的清单。HTTP-FLV 会在本机转成系统播放器可播的 HLS。RTMP、Agora 等专用线路仍需在平台网页观看。房间本身没有更高画面时，清晰度不会变。")
            }
            Section("频道列表") {
                Text("M3U 示例")
                Text("#EXTM3U\n#EXTINF:-1 group-title=\"我的分组\",频道名称\nhttps://example.com/live.m3u8")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("JSON 示例")
                Text("[{\"name\":\"频道名称\",\"url\":\"https://example.com/live.m3u8\",\"group\":\"我的分组\",\"kind\":\"media\"}]")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("移植范围") {
                Text("直播页已接入原服务的平台、房间和播放接口，支持自动连接及更新直播线路。原账户体系与 Android 专用播放组件尚未移植，部分房间可能无法播放。")
                Text("这是重新实现的 iOS 工具，不是原 Android 程序的直接转编译，也不是任何平台的官方客户端。网站可用性与账号权限由各平台决定。")
            }
            Section("安装") {
                Text("此 IPA 面向已安装 TrollStore 的设备。iOS 17.0 巨魔安装不需要 Apple 开发者证书。")
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background).navigationTitle("关于与使用说明")
    }
}
