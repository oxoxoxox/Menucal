//
//  ItsycalFocusStyle.swift
//  Menucal
//

import SwiftUI

/// 保留 Tab 键盘焦点，但用中性色高亮替代系统蓝色焦点方框。
///
/// 焦点状态只能在可聚焦控件的 label 内部通过 `@Environment(\.isFocused)` 读到，
/// 因此这里封装成组件，而不是单纯替换 `ButtonStyle`。
struct ItsycalPlainButton<Label: View>: View {
    private let cornerRadius: CGFloat
    private let action: () -> Void
    private let label: () -> Label

    init(cornerRadius: CGFloat = 4, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.cornerRadius = cornerRadius
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .itsycalFocusHighlight(cornerRadius: cornerRadius)
        }
        .buttonStyle(.plain)
        .itsycalDisableSystemFocusEffect()
    }
}

extension View {
    /// 在控件内容上绘制自定义焦点高亮，需配合 `itsycalDisableSystemFocusEffect()` 使用。
    func itsycalFocusHighlight(cornerRadius: CGFloat = 4) -> some View {
        modifier(ItsycalFocusHighlight(cornerRadius: cornerRadius))
    }

    /// 关闭系统焦点环的视觉效果（macOS 14+），焦点移动与无障碍语义保持不变。
    func itsycalDisableSystemFocusEffect() -> some View {
        modifier(ItsycalSystemFocusEffectDisabled())
    }
}

private struct ItsycalFocusHighlight: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.isFocused) private var isFocused

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if isFocused {
                    shape.fill(Color.primary.opacity(0.07))
                }
            }
            .overlay {
                if isFocused {
                    shape.stroke(Color.primary.opacity(0.45), lineWidth: 1)
                }
            }
    }
}

private struct ItsycalSystemFocusEffectDisabled: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
