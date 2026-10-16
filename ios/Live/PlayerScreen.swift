import SwiftUI
import AVKit
import UIKit

@MainActor
final class PlaybackModel: NSObject, ObservableObject {
    let item: LiveItem
    let player = AVPlayer()
    @Published var error: String?
    @Published var buffering = true
    @Published var pipActive = false
    @Published var isReady = false
    var ready: (() -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var didRecord = false
    private var playTask: Task<Void, Never>?
    private var tunnel: PlaybackTunnel?
    private var attemptFailed = false
    private var attemptError = ""

    init(item: LiveItem) { self.item = item; super.init() }

    func start() {
        playTask?.cancel()
        tunnel?.stop()
        tunnel = nil
        clearObservations()
        error = nil; buffering = true; isReady = false; attemptFailed = false
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { /* Player status reports playback failures; an audio-session warning needn't stop video. */ }
        playTask = Task { await self.playCurrent() }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        tunnel?.stop()
        tunnel = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearObservations()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playCurrent() async {
        let candidates = playbackCandidates
        if candidates.isEmpty {
            begin(item.url, headers: item.headers)
            if await waitUntilReady() || Task.isCancelled { return }
            error = attemptError.isEmpty ? "此直播源暂时无法播放。" : attemptError
            buffering = false
            return
        }
        var last = "此直播源暂时无法播放。"
        for candidate in candidates {
            if Task.isCancelled { return }
            buffering = true
            let tunnel = PlaybackTunnel()
            self.tunnel?.stop()
            self.tunnel = tunnel
            do {
                let local = try await tunnel.open(candidate, headers: item.headers ?? [:])
                if Task.isCancelled { tunnel.stop(); return }
                begin(local, headers: nil)
                if await waitUntilReady() || Task.isCancelled { return }
                last = attemptError.isEmpty ? last : attemptError
            } catch is CancellationError {
                tunnel.stop(); return
            } catch let tunnelError as TunnelError {
                if case .notPlaylist = tunnelError {
                    tunnel.stop()
                    begin(candidate.url, headers: item.headers)
                    if await waitUntilReady() || Task.isCancelled { return }
                    last = attemptError.isEmpty ? tunnelError.localizedDescription : attemptError
                } else { last = tunnelError.localizedDescription }
            } catch let playbackError {
                last = playbackError.localizedDescription
            }
            tunnel.stop()
        }
        if !Task.isCancelled {
            self.error = last
            buffering = false
        }
    }

    private var playbackCandidates: [StreamCandidate] {
        if let streams = item.streams, !streams.isEmpty { return streams }
        if let kind = StreamKind.classify(item.url) { return [StreamCandidate(url: item.url, kind: kind)] }
        return []
    }

    private func begin(_ url: URL, headers: [String: String]?) {
        clearObservations()
        attemptFailed = false
        attemptError = ""
        isReady = false
        buffering = true
        let asset = AVURLAsset(url: url, options: headers.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] } ?? [:])
        let playerItem = AVPlayerItem(asset: asset)
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: playerItem)
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] value, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === value else { return }
                switch value.status {
                case .readyToPlay:
                    self.isReady = true
                    if !self.didRecord { self.didRecord = true; self.ready?() }
                case .failed:
                    self.attemptFailed = true
                    self.attemptError = value.error?.localizedDescription ?? "此直播源暂时无法播放。"
                    self.buffering = false
                    if self.isReady { self.error = self.attemptError }
                default: break
                }
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attemptFailed = true
                self.attemptError = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "播放中断，请重试。"
                self.buffering = false
                if self.isReady { self.error = self.attemptError }
            }
        }
        player.play()
    }

    private func waitUntilReady() async -> Bool {
        let deadline = Date().addingTimeInterval(18)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if isReady { return true }
            if attemptFailed { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return isReady
    }

    private func clearObservations() {
        statusObservation?.invalidate(); statusObservation = nil
        timeObservation?.invalidate(); timeObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
    }
}

private struct NativePlayer: UIViewControllerRepresentable {
    let model: PlaybackModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: PlaybackModel
        init(model: PlaybackModel) { self.model = model }
        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor [weak model] in model?.pipActive = true }
        }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            Task { @MainActor [weak model] in model?.pipActive = false }
        }
        func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
    }
}

struct PlayerScreen: View {
    let item: LiveItem
    let onReconnect: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model: PlaybackModel

    init(item: LiveItem, onReconnect: (() -> Void)? = nil) {
        self.item = item; self.onReconnect = onReconnect
        _model = StateObject(wrappedValue: PlaybackModel(item: item))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(model: model).ignoresSafeArea(edges: .bottom)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("视频播放器")
                .accessibilityValue(model.isReady ? "已就绪" : "连接中")
                .accessibilityIdentifier("nativePlayer")
            if model.buffering, model.error == nil {
                VStack(spacing: 12) { ProgressView().tint(.white); Text("正在连接直播源…").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                    .padding(22).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18)).allowsHitTesting(false)
            }
            if let error = model.error {
                VStack(spacing: 16) {
                    QuietEmpty(symbol: "play.slash", title: "暂时无法播放", detail: error)
                    Button("重新连接") { if let onReconnect { onReconnect() } else { model.start() } }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background)
                    Button("在 Safari 中打开") { UIApplication.shared.open(item.url) }.buttonStyle(.bordered)
                    Text("直播地址可能已过期，或需要网站登录、特殊播放器。可以返回平台网页继续观看。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                }.frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            }
        }
        .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityLabel("关闭播放") }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleFavorite(item) } label: { Image(systemName: library.isFavorite(item) ? "heart.fill" : "heart") }.accessibilityLabel("收藏视频")
                ShareLink(item: item.url)
            }
        }
        .onAppear { model.ready = { library.record(item) }; model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !library.backgroundAudio, !model.pipActive { model.player.pause() }
        }
    }
}
