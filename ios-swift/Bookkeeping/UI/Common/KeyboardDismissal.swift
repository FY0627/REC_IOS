import SwiftUI
import UIKit

extension View {
    /// 点输入框以外的地方收起键盘（数字键盘没有收起键）。放在根视图上，整个 App（包括弹出的页面）都有效
    func dismissesKeyboardOnTapOutside() -> some View {
        background(KeyboardDismissal())
    }
}

/// 在窗口上装一个点按识别：点到输入框以外的地方就结束输入。
/// 不拦截点按（`cancelsTouchesInView = false`，和其他手势同时识别）：点到按钮、列表行、卡片照常响应。
/// 不在键盘上方加「收起」按钮：那一栏收起时底部会闪白条
private struct KeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView {
        InstallerView()
    }

    func updateUIView(_ view: InstallerView, context: Context) {}

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window !== installedWindow else { return }
            installedWindow?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
            installedWindow = window
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            recognizer.view?.endEditing(true)
        }

        /// 点在输入框里是在输入、移动光标或点清除按钮，不收起。点在 UIKit 按钮上也不收起：
        /// 按钮自己决定（例如首页的搜索按钮要弹出键盘，同时收起就会冲突）
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
