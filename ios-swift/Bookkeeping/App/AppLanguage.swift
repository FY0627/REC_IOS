import SwiftUI
import ObjectiveC
import BKModel

/// App 的显示语言：跟随系统，或者在「我的 › 语言」里选的简体中文、繁體中文（台灣）、English（ADR 0022）。
///
/// 选的语言写在 App 自己的 `AppleLanguages` 里，和系统「设置 › REC › 语言」是同一个值：下次打开 App 时
/// 系统直接按它加载，日期、系统按钮也跟着变。当时就换：界面文字按选的语言查（`L`、`.loc`、根视图的 `locale`），
/// 根视图按语言重建（`BookkeepingApp`）。
///
/// 文字在 `Localizable.xcstrings`：键就是简体中文原文，另有 zh-Hant（台湾用语）和 en。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    /// 界面上观察用的副本（`@AppStorage`）：真正的值在 `AppleLanguages` 里，数组不能直接观察
    static let key = "appLanguage"

    /// 选项名称：每种语言用它自己的文字写，「跟随系统」跟着现在的语言
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文（台灣）"
        case .english: "English"
        }
    }

    /// 用户选的（含跟随系统）：读 App 自己的 `AppleLanguages`，系统设置里改的也算
    static var selected: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return supported(first) ?? .system
    }

    /// 实际显示的语言
    static var resolved: AppLanguage { state.resolved }

    /// 查文字用的语言包：对应语言的 `.lproj`；没有时用主包（键就是简体中文，查不到原样显示）
    static var bundle: Bundle { state.bundle }

    /// 日期、复数用的地区设置
    static var locale: Locale { state.locale }

    /// 换语言：写进 `AppleLanguages`（跟随系统时删掉），再更新当时用的语言和界面观察的副本
    @MainActor static func select(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
        state = State(resolving: language)
        defaults.set(language.rawValue, forKey: key)
    }

    /// 启动时：界面观察的副本对上 `AppleLanguages`，主包查文字时也按选的语言（`LanguageBundle`）
    static func prepare() {
        UserDefaults.standard.set(selected.rawValue, forKey: key)
        if !(Bundle.main is LanguageBundle) { object_setClass(Bundle.main, LanguageBundle.self) }
    }

    /// 系统的语言代码（`zh-Hant-TW`、`en-GB`）对应的语言；不支持的是 nil
    private static func supported(_ code: String) -> AppLanguage? {
        let match = Bundle.preferredLocalizations(from: [zhHans.rawValue, zhHant.rawValue, english.rawValue], forPreferences: [code]).first
        guard let match, let language = AppLanguage(rawValue: match) else { return nil }
        // 只给了一个候选时系统会退回第一个，要再对一下语言
        let lower = code.lowercased()
        switch language {
        case .english: return lower.hasPrefix("en") ? language : nil
        case .zhHans, .zhHant: return lower.hasPrefix("zh") ? language : nil
        case .system: return nil
        }
    }

    /// 当时用的语言。主线程换，别的线程（后台入账发通知）只读
    private nonisolated(unsafe) static var state = State(resolving: selected)

    private struct State {
        let resolved: AppLanguage
        let bundle: Bundle
        let locale: Locale

        init(resolving choice: AppLanguage) {
            var language = choice
            if language == .system {
                // 跟随系统：按系统的语言顺序挑第一个支持的；都不支持时用英文
                language = Locale.preferredLanguages.lazy.compactMap(AppLanguage.supported).first ?? .english
            }
            resolved = language
            bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
            locale = switch language {
            case .zhHant: Locale(identifier: "zh_Hant_TW")
            case .english: Locale(identifier: "en_US")
            default: Locale(identifier: "zh_Hans_CN")
            }
        }
    }
}

/// 主包查界面文字时改查选的语言（SwiftUI 的 `Text("…")` 等），换了语言当时就生效，不用重开 App
private final class LanguageBundle: Bundle {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let target = AppLanguage.bundle
        guard target !== self else { return super.localizedString(forKey: key, value: value, table: tableName) }
        return target.localizedString(forKey: key, value: value, table: tableName)
    }
}

/// 界面文字（写在代码里的简体中文，可以带 `\(数量)` 这类插值）换成选的语言
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppLanguage.bundle, locale: AppLanguage.locale)
}

extension String {
    /// 账本给的中文名称（类型、状态、来源、默认分类、银行……）换成选的语言。
    /// 目录里没有的原样返回：用户自己起的名字、写的备注不受影响
    var loc: String { AppLanguage.bundle.localizedString(forKey: self, value: self, table: nil) }
}

extension View {
    /// UIKit 里单独放的 SwiftUI 内容（`UIHostingController`）不继承根视图的环境，要自己设
    func appLocale() -> some View {
        environment(\.locale, AppLanguage.locale)
    }
}
