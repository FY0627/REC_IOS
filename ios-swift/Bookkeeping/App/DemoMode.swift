import Foundation
import BKBackend

/// 演示数据（ADR 0025）：「我的 › 开发与调试」里的开关，给官网录屏和截图用。
///
/// 打开时 App 换成一份单独的演示账本（`Application Support/Demo/`，卡面图片、导入前的副本也在里面），
/// 每次打开都按当时的 App 语言重新生成（`LedgerBackend.seedDemo`）。真实账本（`Application Support/Ledger/`）
/// 演示期间不读不写；自动记账、灵动岛、截图记账都记到演示账本里。
///
/// 设置：打开时把 App 自己的整份设置存一份，关掉时原样换回去（演示期间改的主要币种、主题色、记账结果、语言都恢复），
/// 汇率缓存也在里面。开关本身和这份副本不在恢复范围里。
enum DemoMode {
    private static let activeKey = "demo.active"
    private static let savedSettingsKey = "demo.savedSettings"
    private static let languageKey = "demo.language"
    private static let ownKeys: Set<String> = [activeKey, savedSettingsKey, languageKey]

    /// 现在用的是演示账本。任何线程都可以读（App Intent 在后台打开账本时也看它）
    static var isActive: Bool { UserDefaults.standard.bool(forKey: activeKey) }

    /// 演示账本写的语言（模拟消费页显示商户用）
    static var language: DemoLanguage? {
        guard isActive else { return nil }
        return UserDefaults.standard.string(forKey: languageKey).flatMap(DemoLanguage.init(rawValue:))
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Demo", isDirectory: true)
    }

    /// 演示账本的文件还在（App 被系统清理过临时数据、或者上次没写完时不在）
    static var ledgerExists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("ledger.sqlite").path)
    }

    /// 按 App 现在显示的语言
    static var currentLanguage: DemoLanguage {
        switch AppLanguage.resolved {
        case .zhHant: .zhHant
        case .english: .english
        default: .zhHans
        }
    }

    /// 打开：存好现在的设置，删掉上次的演示账本，换过去。之后 `AppServices` 打开的就是演示账本
    static func activate(language: DemoLanguage) throws {
        let defaults = UserDefaults.standard
        if !isActive {
            let domain = (defaults.persistentDomain(forName: bundleID) ?? [:]).filter { !ownKeys.contains($0.key) }
            let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
            defaults.set(data, forKey: savedSettingsKey)
        }
        removeFiles()
        defaults.set(language.rawValue, forKey: languageKey)
        defaults.set(true, forKey: activeKey)
    }

    /// 关掉：设置换回打开前的样子，再让语言、图标、主题色、汇率马上生效。之后 `AppServices` 打开的是真实账本
    @MainActor static func deactivate() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: savedSettingsKey),
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            let current = defaults.persistentDomain(forName: bundleID) ?? [:]
            for key in current.keys where saved[key] == nil && !ownKeys.contains(key) {
                defaults.removeObject(forKey: key)
            }
            // 一样的不写：每写一个，读它的界面都要重画
            for (key, value) in saved where !((current[key] as? NSObject)?.isEqual(value) ?? false) {
                defaults.set(value, forKey: key)
            }
        }
        for key in ownKeys { defaults.removeObject(forKey: key) }
        // 语言写在 `AppleLanguages` 里，刚换回来了：当时用的语言和界面观察的副本跟着对上
        AppLanguage.select(AppLanguage.selected)
        AppearanceMode.applyIcon()
        ThemeColor.applyToWindows()
        NotificationCenter.default.post(name: .exchangeRatesDidChange, object: nil)
    }

    /// 删掉演示账本的文件（数据库、卡面图片）。真实账本在另一个文件夹，不受影响
    static func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.fy0627.rec" }
}
