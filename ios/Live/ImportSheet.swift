import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var useSubscription = true
    @State private var input = ""
    @State private var preview: [LiveItem] = []
    @State private var sourceURL: URL?
    @State private var error: String?
    @State private var busy = false
    @State private var showFile = false
    @State private var success = false
    @State private var task: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            content
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("导入频道").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if !preview.isEmpty {
                        Button("导入", action: savePreview).disabled(busy).accessibilityIdentifier("saveChannels")
                    }
                }
            }
            .onChange(of: input) { _, _ in preview = []; sourceURL = nil; error = nil }
            .onChange(of: useSubscription) { _, _ in input = ""; preview = []; sourceURL = nil; error = nil }
            .onDisappear { task?.cancel() }
            .alert("导入完成", isPresented: $success) {
                Button("完成") { dismiss() }
            } message: { Text("频道已保存，可在「直播 → 我的频道」中观看。") }
            .fileImporter(isPresented: $showFile, allowedContentTypes: [.data], allowsMultipleSelection: false, onCompletion: fileImported)
        }
        .preferredColorScheme(.dark).tint(Theme.accent)
    }

    private var content: some View {
        Form {
            inputSection
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if !preview.isEmpty { previewSection }
        }
    }

    private var inputSection: some View {
        Section {
            Picker("来源", selection: $useSubscription) {
                Text("订阅地址").tag(true)
                Text("粘贴内容").tag(false)
            }.pickerStyle(.segmented).disabled(busy)
            inputField
            HStack {
                Button(action: parseInput) {
                    if busy { HStack { ProgressView(); Text("正在读取…") } }
                    else { Label("读取频道", systemImage: "arrow.down.doc") }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                .accessibilityIdentifier("readChannels")
                Spacer()
                Button { showFile = true } label: { Label("选文件", systemImage: "folder") }.disabled(busy)
            }
        } footer: {
            Text("支持 M3U、JSON 和每行一个链接的文本，最大 5 MB / 5000 个频道。HLS 的 .m3u8 播放地址请在「打开链接」中播放。")
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if useSubscription {
            TextField("https://example.com/channels.m3u", text: $input, axis: .vertical)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("subscriptionURL").disabled(busy).focused($inputFocused)
        } else {
            TextEditor(text: $input).frame(minHeight: 140).font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                .accessibilityIdentifier("playlistContent").focused($inputFocused)
        }
    }

    private var previewSection: some View {
        Section {
            ForEach(Array(preview.prefix(8))) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.subheadline)
                    Text(item.group.isEmpty ? item.host : item.group).font(.caption).foregroundStyle(.secondary)
                }
            }
            if preview.count > 8 { Text("另有 \(preview.count - 8) 个频道").font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("已识别 \(preview.count) 个频道")
        } footer: {
            Text("相同地址的频道会更新名称与分组。订阅刷新会合并频道，不会自动删除已导入频道。")
        }
    }

    private func savePreview() {
        do { _ = try library.importItems(preview, subscriptionURL: sourceURL); success = true }
        catch { self.error = error.localizedDescription }
    }

    private func fileImported(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): if let url = urls.first { parseFile(url) }
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    private func parseInput() {
        inputFocused = false
        error = nil; preview = []; sourceURL = nil
        if !useSubscription {
            do { preview = try PlaylistParser.parse(Data(input.utf8)) }
            catch { self.error = error.localizedDescription }
            return
        }
        do {
            let url = try LinkValidator.parse(input)
            busy = true
            task = Task { @MainActor in
                defer { busy = false }
                do {
                    let items = try await PlaylistFetcher.load(url)
                    guard !Task.isCancelled else { return }
                    preview = items; sourceURL = url
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func parseFile(_ url: URL) {
        error = nil; preview = []; sourceURL = nil; busy = true
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    if (values.fileSize ?? 0) > PlaylistParser.maximumBytes { throw LiveError.tooLarge }
                    return try PlaylistParser.parse(Data(contentsOf: url))
                }.value
                guard !Task.isCancelled else { return }
                preview = items
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
