# 直播 · iOS 17 巨魔版

根据提供的 `Stripchat直播.apk` 进行静态分析后，重新实现的 SwiftUI / WebKit / AVKit 应用，最低 iOS 17.0，支持 iPhone 与 iPad。

在 GitHub Releases 下载 `Live-iOS17-TrollStore.ipa`，通过 iPhone「文件 → 分享 → TrollStore」安装。无需 Apple 开发者证书。仓库默认私有，下载需要登录所属 GitHub 账号。

已实现的功能：

- 原 APK 中出现的平台主页入口，在内置浏览器观看与登录；保留 Cookie。
- 收藏当前网页或视频、分享链接、观看记录。
- HLS / M3U8、MP4 等兼容视频直链，使用系统播放器。
- 播放器的画中画、AirPlay 与可选择的后台视频播放。
- 从订阅、文件或粘贴内容导入 M3U、JSON、文本频道列表。
- 频道名称搜索、分组筛选、订阅合并刷新、删除频道。
- 清除网页缓存与登录状态；本机保存收藏与资料。

**移植范围：** 平台入口是网页观看；原应用私有房间列表、账户体系、Android 专有隧道、付费内容接口尚未接通。本应用不伪装这些功能已恢复，也未使用 APK 内的测试账户凭据。单个平台、登录、地区限制和视频源能否使用取决于平台与网络。需要 FLV / RTMP、DRM、特殊请求头或专有 RTC SDK 的链接不保证系统播放器可播。

工程不依赖 Flutter、CocoaPods 或第三方 iOS 播放 SDK。原 APK、恢复的 DEX、Android 库和逆向结果包均未上传。

## 本地构建

在有 Xcode 的 macOS 上：

```bash
brew install xcodegen
bash scripts/build_ipa.sh
```

产物位于 `dist/Live-iOS17-TrollStore.ipa`。脚本生成 Xcode 工程、构建 ARM64 真机应用、ad-hoc 签名并验证包结构和 iOS 17.0 部署版本。

## GitHub 构建与验证

推送 `main` 或手动运行 Actions 的 `Build iOS 17 IPA`：

1. 生成工程。
2. 运行解析器、URL 校验、资料持久化与界面测试。
3. 保存模拟器界面截图与 XCTest 结果。
4. 构建 ARM64 IPA，检查版本、架构、资源与签名。
5. 上传 Actions 产物，并在此私有仓库创建 Release。

CI 使用本地测试网页、生成的纯色静音 MP4 / HLS 视频和订阅文件，验证网页加载与收藏、原生视频就绪、URL 校验、订阅读取、粘贴导入、持久化和页面导航，不访问平台的直播内容。模拟器测试与编译不等同于在用户 iOS 17.0 真机上验证所有网站及流媒体。

## 逆向阶段

已解开 Android 加固，恢复 30,026 个加密方法及 Flutter Android 业务库。原 APK 身份、解密证据与复现方式见 [逆向分析.md](逆向分析.md)。

该阶段的恢复结果是 Android 编译产物，并非 Dart 源码；本 iOS 工程是独立重写。
