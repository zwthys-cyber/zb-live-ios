import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published var notice: String?
    private let fileURL: URL?
    private var canSave = true

    init(fileURL: URL? = nil, ephemeral: Bool = false) {
        if ephemeral { self.fileURL = nil; return }
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Live/library.json")
        if let path = self.fileURL, FileManager.default.fileExists(atPath: path.path) {
            do { snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: path)) }
            catch {
                let backup = path.appendingPathExtension("backup-\(Int(Date().timeIntervalSince1970))")
                do {
                    try FileManager.default.copyItem(at: path, to: backup)
                    notice = "保存的资料未能读取，已保留原始备份。本次将创建新的资料文件。"
                } catch {
                    canSave = false
                    notice = "保存的资料未能读取，原文件仍保留。当前更改暂不写入，请重启重试。"
                }
            }
        }
    }

    var favorites: [LiveItem] { snapshot.favorites }
    var channels: [LiveItem] { snapshot.channels }
    var subscriptions: [Subscription] { snapshot.subscriptions }
    var history: [WatchRecord] { snapshot.history }
    var backgroundAudio: Bool { snapshot.backgroundAudio }

    func isFavorite(_ item: LiveItem) -> Bool { favorites.contains { $0.id == item.id } }

    func toggleFavorite(_ item: LiveItem) {
        if isFavorite(item) { snapshot.favorites.removeAll { $0.id == item.id } }
        else { snapshot.favorites.insert(item, at: 0) }
        save()
    }

    func removeFavorite(_ offsets: IndexSet) {
        for index in offsets.sorted(by: >) where index < snapshot.favorites.count { snapshot.favorites.remove(at: index) }
        save()
    }

    func record(_ item: LiveItem, date: Date = Date()) {
        snapshot.history.removeAll { $0.id == item.id }
        snapshot.history.insert(WatchRecord(item: item, date: date), at: 0)
        snapshot.history = Array(snapshot.history.prefix(200))
        save()
    }

    func importItems(_ items: [LiveItem], subscriptionURL: URL? = nil) -> Int {
        var byID = Dictionary(snapshot.channels.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for item in items { byID[item.id] = item }
        let prior = Set(snapshot.channels.map(\.id))
        var ordered = snapshot.channels.map { byID[$0.id] ?? $0 }
        ordered.append(contentsOf: items.filter { !prior.contains($0.id) })
        var seen = Set<String>()
        snapshot.channels = Array(ordered.filter { seen.insert($0.id).inserted }.prefix(PlaylistParser.maximumChannels))
        if let url = subscriptionURL {
            snapshot.subscriptions.removeAll { $0.url == url }
            snapshot.subscriptions.insert(Subscription(url: url, name: url.host ?? "频道列表", updated: Date()), at: 0)
        }
        save()
        return items.count
    }

    func removeChannel(_ item: LiveItem) { snapshot.channels.removeAll { $0.id == item.id }; save() }
    func removeSubscription(_ source: Subscription) { snapshot.subscriptions.removeAll { $0.id == source.id }; save() }
    func clearHistory() { snapshot.history.removeAll(); save() }
    func clearChannels() { snapshot.channels.removeAll(); snapshot.subscriptions.removeAll(); save() }
    func setBackgroundAudio(_ value: Bool) { snapshot.backgroundAudio = value; save() }

    private func save() {
        guard let fileURL, canSave else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch { notice = "资料保存失败：\(error.localizedDescription)" }
    }
}
