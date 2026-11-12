import Foundation
import UIKit

/// 测试反馈问卷（Microsoft Forms「REC 记账测试反馈」）：「我的 › 关于 › 反馈」用 Safari 打开。
/// 第 1–3 题（机型、iOS 版本、App 版本）预先填好，测试员不用自己查，每条反馈也对得上是哪个构建。
/// 参数名是问卷里这三题的编号，在 Forms 的「获取预填充的 URL」里生成；改了这三题要重新生成
enum FeedbackForm {
    private static let base = "https://forms.cloud.microsoft/Pages/ResponsePage.aspx?id=DQSIkWdsW0yxEjajBLZtrQAAAAAAAAAAAAO__r3LwqNUQjlBU0NIQVgxMlVSM1BOUVVVRlE2S0g3Ry4u"
    private static let modelField = "r3e564b677d074f78b82c1f84e0039018"
    private static let systemField = "rbd739aec09da445d84f680580c0c158a"
    private static let appField = "r7ba9f4bba56f47698abc9e3fb26f6308"

    @MainActor
    static var url: URL {
        guard var components = URLComponents(string: base) else { return URL(string: base)! }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: modelField, value: LiveCategoryActivity.modelIdentifier),
            URLQueryItem(name: systemField, value: UIDevice.current.systemVersion),
            URLQueryItem(name: appField, value: BuildInfo.summary),
        ]
        return components.url ?? URL(string: base)!
    }
}
