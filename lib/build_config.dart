/// 构建期开关。
///
/// 商店版本由 Microsoft Store 负责分发与更新，应用内不再提供 GitHub
/// 更新检查入口，避免引导用户到商店之外获取新版本。
///
/// 用法：
/// `flutter build windows --release --dart-define=STORE_BUILD=true`
const bool kStoreBuild = bool.fromEnvironment('STORE_BUILD');
