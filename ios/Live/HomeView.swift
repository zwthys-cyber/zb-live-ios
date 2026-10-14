import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: PlayerRouter
    @State private var search = ""
    @State private var showOpen = false
    @State private var showImport = false
    @State private var pending: LiveItem?
    @State private var selectedGroup = "全部"

    private var platforms: [LiveItem] {
        Platforms.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var groups: [String] { ["全部"] + Set(library.channels.map(\.group).filter { !$0.isEmpty }).sorted() }
    private var channels: [LiveItem] {
        library.channels.filter {
            (selectedGroup == "全部" || $0.group == selectedGroup) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20).fill(Theme.accent).frame(width: 62, height: 62)
                        Image(systemName: "play.rectangle.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.background)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("随时打开，随心观看").font(.headline)
                        Text("平台网页 · 视频直链 · 我的频道").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Theme.accent.opacity(0.12), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))

                HStack(spacing: 12) {
                    Button { showOpen = true } label: { Label("打开链接", systemImage: "link").frame(maxWidth: .infinity).padding(.vertical, 12) }
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).accessibilityIdentifier("openLink")
                    Button { showImport = true } label: { Label("导入频道", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 12) }
                        .buttonStyle(.bordered).accessibilityIdentifier("importChannels")
                }
                .font(.subheadline.weight(.semibold))

                if search.isEmpty, let recent = library.history.first {
                    SectionCaption(title: "最近观看")
                    Button { router.open(recent.item) } label: { ItemRow(item: recent.item, trailing: "play.fill") }.buttonStyle(.plain)
                }

                SectionCaption(title: "平台入口", detail: "网页观看")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                    ForEach(platforms) { item in
                        let index = Platforms.all.firstIndex(of: item) ?? 0
                        Button { router.open(item) } label: {
                            VStack(alignment: .leading, spacing: 22) {
                                HStack {
                                    Text(String(item.name.prefix(1))).font(.title2.weight(.bold))
                                        .foregroundStyle(Theme.palette[index % Theme.palette.count])
                                        .frame(width: 46, height: 46)
                                        .background(Theme.palette[index % Theme.palette.count].opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.name).font(.subheadline.weight(.bold)).foregroundStyle(.primary).lineLimit(1)
                                    Text("网页观看").font(.caption2).foregroundStyle(Theme.muted)
                                }
                            }
                            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("平台内容与登录由各网站提供，访问情况取决于平台与当前网络。")
                    .font(.caption2).foregroundStyle(Theme.muted).padding(.horizontal, 2)

                SectionCaption(title: "我的频道", detail: "\(library.channels.count) 个")
                if !library.channels.isEmpty {
                    if groups.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(groups, id: \.self) { group in
                                    Button(group) { selectedGroup = group }
                                        .font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(selectedGroup == group ? Theme.accent : Theme.surface, in: Capsule())
                                        .foregroundStyle(selectedGroup == group ? Theme.background : Theme.muted)
                                }
                            }
                        }
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(channels) { item in
                            Button { router.open(item) } label: { ItemRow(item: item) }.buttonStyle(.plain)
                                .contextMenu {
                                    Button { library.toggleFavorite(item) } label: { Label(library.isFavorite(item) ? "取消收藏" : "收藏", systemImage: "heart") }
                                    ShareLink(item: item.url)
                                    Button("移除频道", role: .destructive) { library.removeChannel(item) }
                                }
                        }
                    }
                    if channels.isEmpty { QuietEmpty(symbol: "magnifyingglass", title: "没有匹配频道", detail: "试试其他名称或分组。") }
                } else {
                    Button { showImport = true } label: {
                        QuietEmpty(symbol: "rectangle.stack.badge.plus", title: "把常看的频道放在这里", detail: "导入 M3U、JSON，或粘贴频道列表。")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20).frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("直播")
        .searchable(text: $search, prompt: "搜索平台或频道")
        .sheet(isPresented: $showOpen, onDismiss: {
            if let item = pending { pending = nil; router.open(item) }
        }) { OpenLinkSheet { pending = $0 } }
        .sheet(isPresented: $showImport) { ImportSheet() }
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: PlayerRouter
    var body: some View {
        Group {
            if library.favorites.isEmpty {
                QuietEmpty(symbol: "heart", title: "还没有收藏", detail: "观看时点击爱心，保存当前网页或视频。")
            } else {
                List {
                    ForEach(library.favorites) { item in
                        Button { router.open(item) } label: { ItemRow(item: item) }
                            .buttonStyle(.plain).listRowSeparator(.hidden)
                            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
                    }
                    .onDelete(perform: library.removeFavorite)
                }
                .scrollContentBackground(.hidden).listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle("收藏")
        .toolbar { if !library.favorites.isEmpty { EditButton() } }
    }
}

enum OpenMode: String, CaseIterable {
    case automatic = "自动"
    case web = "网页"
    case media = "视频"
}

struct OpenLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    var opened: (LiveItem) -> Void
    @State private var urlText = ""
    @State private var name = ""
    @State private var mode = OpenMode.automatic
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("链接地址") {
                    TextField("https://", text: $urlText, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("linkURL")
                    PasteButton(payloadType: String.self) { values in if let text = values.first { urlText = text } }
                }
                Section("打开方式") {
                    Picker("打开方式", selection: $mode) { ForEach(OpenMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    TextField("名称（可选）", text: $name).accessibilityIdentifier("linkName")
                }
                Section {
                    Text("网页链接使用内置浏览器；M3U8、MP4 等视频直链使用系统播放器。网页内的登录状态会保留。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("linkError") }
                }
            }
            .navigationTitle("打开链接").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("打开") {
                        do {
                            let url = try LinkValidator.parse(urlText)
                            let kind: LinkKind? = mode == .automatic ? nil : (mode == .web ? .web : .media)
                            opened(LiveItem(name: name, url: url, kind: kind))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirmOpen")
                }
            }
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
    }
}
