import SwiftUI
import WebKit
import UIKit

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let original: LiveItem
    @Published var progress = 0.0
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL
    @Published var error: String?
    @Published var externalURL: URL?
    var visited: ((LiveItem) -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(item: LiveItem) {
        original = item
        currentURL = item.url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "LiveIOS/1.0"
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Theme.background)
        webView.scrollView.backgroundColor = UIColor(Theme.background)
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.loading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor [weak self] in
                    if let url = view.url, let checked = try? LinkValidator.parse(url.absoluteString) { self?.currentURL = checked }
                }
            }
        ]
    }

    var currentItem: LiveItem { LiveItem(name: original.name, url: currentURL, kind: .web, group: original.group) }

    func start() {
        error = nil
        webView.load(URLRequest(url: original.url, timeoutInterval: 40))
    }

    func reload() {
        error = nil
        if webView.url == nil { start() } else { webView.reload() }
    }

    func stop() {
        webView.stopLoading()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        error = nil
        if let url = webView.url, let checked = try? LinkValidator.parse(url.absoluteString) {
            currentURL = checked
            visited?(currentItem)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "网页暂时停止响应，请刷新重试。" }

    private func failed(_ failure: Error) {
        let value = failure as NSError
        guard value.code != NSURLErrorCancelled, value.code != 102 else { return }
        error = failure.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            // Website redirects never silently launch another app. A tapped link gets a prompt.
            if navigationAction.navigationType == .linkActivated { externalURL = url }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           (try? LinkValidator.parse(url.absoluteString)) != nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    private func presenter(for view: WKWebView) -> UIViewController? {
        var controller = view.window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let controller = presenter(for: webView), !(controller is UIAlertController) else { completionHandler(); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        controller.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let controller = presenter(for: webView), !(controller is UIAlertController) else { completionHandler(false); return }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        controller.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let controller = presenter(for: webView), !(controller is UIAlertController) else { completionHandler(nil); return }
        let alert = UIAlertController(title: webView.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        controller.present(alert, animated: true)
    }
}

private struct BrowserCanvas: UIViewRepresentable {
    let model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model: BrowserModel

    init(item: LiveItem) { _model = StateObject(wrappedValue: BrowserModel(item: item)) }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading { ProgressView(value: model.progress).tint(Theme.accent).frame(height: 2) }
            if let error = model.error {
                VStack(spacing: 16) {
                    QuietEmpty(symbol: "wifi.exclamationmark", title: "网页未能加载", detail: error)
                    Button("重新加载") { model.reload() }.buttonStyle(.borderedProminent)
                    Button("在 Safari 中打开") { UIApplication.shared.open(model.currentURL) }.buttonStyle(.bordered)
                    Text("如果平台限制内置浏览器，可在 Safari 中继续。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            } else { BrowserCanvas(model: model) }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityLabel("关闭网页") }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 3) {
                    Text(model.original.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(model.currentURL.host ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { library.toggleFavorite(model.currentItem) } label: { Image(systemName: library.isFavorite(model.currentItem) ? "heart.fill" : "heart") }.accessibilityLabel("收藏当前页面")
                Menu {
                    ShareLink(item: model.currentURL)
                    Button("在 Safari 中打开", systemImage: "safari") { UIApplication.shared.open(model.currentURL) }
                    Button("复制地址", systemImage: "doc.on.doc") { UIPasteboard.general.url = model.currentURL }
                    Button("刷新", systemImage: "arrow.clockwise") { model.reload() }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("网页菜单")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).accessibilityLabel("后退")
                Spacer()
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).accessibilityLabel("前进")
                Spacer()
                Text("网页观看").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if model.loading { model.webView.stopLoading() } else { model.reload() }
                } label: { Image(systemName: model.loading ? "xmark" : "arrow.clockwise") }.accessibilityLabel("刷新或停止")
            }
        }
        .onAppear { model.visited = { library.record($0) }; model.start() }
        .onDisappear { model.stop() }
        .alert("使用其他应用打开？", isPresented: Binding(get: { model.externalURL != nil }, set: { if !$0 { model.externalURL = nil } })) {
            Button("取消", role: .cancel) { model.externalURL = nil }
            Button("打开") { if let url = model.externalURL { UIApplication.shared.open(url) }; model.externalURL = nil }
        } message: { Text(model.externalURL?.scheme ?? "") }
    }
}
