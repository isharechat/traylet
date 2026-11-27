import SwiftUI

/// A grouped list in the System Settings style: rows separated by hairlines inside one rounded card, with an optional footnote.
struct SettingsGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs + 2) {
            VStack(alignment: .leading, spacing: 0, content: content).padding(.horizontal, Design.Space.m + 2)
                .frame(maxWidth: .infinity, alignment: .leading).v2SettingsCard(contrast: contrast)
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Design.Space.m + 2) }
        }
    }
}

/// One settings row: title on the left, control on the right, at least 40pt tall.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control
    var body: some View { HStack(spacing: Design.Space.m) { Text(title); Spacer(minLength: Design.Space.m); control() }.frame(minHeight: 40) }
}

extension View {
    /// The card fill and hairline used by every settings group.
    func v2SettingsCard(contrast: ColorSchemeContrast) -> some View {
        v2GlassBackground(in: RoundedRectangle(cornerRadius: Design.Radius.card))
    }
}

/// Expand/collapse pill button for configurable AI/external engines.
struct EngineConfigureButton: View {
    let open: Bool
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                Text(L("配置")).font(.caption.weight(.medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundStyle(open ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(
                open ? Color.accentColor.opacity(hovering ? 0.2 : 0.15)
                     : Color(nsColor: hovering ? .tertiarySystemFill : .quaternarySystemFill),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L(open ? "收起配置" : "展开配置"))
        .accessibilityLabel(L("配置") + " " + title)
        .accessibilityValue(L(open ? "已展开" : "已收起"))
    }
}

/// Shared default-engine status badge or "Set as Default" capsule action.
struct EngineDefaultControl: View {
    let isDefault: Bool
    let title: String
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        if isDefault {
            StatusPill(text: L("默认"), tint: .secondary)
        } else {
            Button(action: onSelect) {
                Text(L("设为默认"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Color.accentColor.opacity(hovering ? 0.2 : 0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(L("设为默认"))
            .accessibilityLabel(L("设为默认") + " " + title)
        }
    }
}

/// Unified model text field + dropdown popover picker for AI engines.
struct AIModelComboField: View {
    @Binding var model: String
    let models: [String]
    @Binding var showsPicker: Bool
    var focused: FocusState<Bool>.Binding
    let identifier: String
    let onCommit: () -> Void

    var body: some View {
        LabeledContent(L("模型")) {
            HStack(spacing: 0) {
                TextField(L("模型"), text: $model)
                    .labelsHidden().textFieldStyle(.plain).focused(focused)
                    .multilineTextAlignment(.leading)
                    .onSubmit(onCommit)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity)
                Divider().frame(height: 16)
                Button { onCommit(); showsPicker.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsPicker ? 180 : 0))
                        .foregroundStyle(showsPicker ? Color.accentColor : Color.secondary)
                        .frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("从已获取的模型中选择"))
                .accessibilityLabel(L("选择模型"))
                .accessibilityValue(L(showsPicker ? "已展开" : "已收起"))
                .accessibilityIdentifier(identifier)
            }
            .frame(height: 24)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(focused.wrappedValue || showsPicker ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                TranslationModelPicker(
                    models: models,
                    selection: Binding(get: { model }, set: { model = $0; onCommit() }),
                    isPresented: $showsPicker
                )
            }
            .onDisappear { showsPicker = false }
        }
    }
}

/// Unified async action button (Fetch Models / Test Connection) with inline status feedback.
struct AISettingsActionButton: View {
    let isRunning: Bool
    let feedback: TranslationActionFeedback?
    let isBusy: Bool
    let idle: String
    let running: String
    let success: String
    let failure: String
    let help: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        let failureMessage: String? = if case .failure(let message)? = feedback { message } else { nil }
        Button(action: action) {
            HStack(spacing: 5) {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text(L(running))
                } else if case .success? = feedback {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L(success))
                } else if failureMessage != nil {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(L(failure))
                } else {
                    Text(L(idle))
                }
            }.frame(minWidth: 82)
        }
        .disabled(isBusy)
        .help(L(failureMessage ?? help))
        .accessibilityIdentifier(identifier)
        .accessibilityValue(L(failureMessage ?? (feedback == .success ? success : isRunning ? running : idle)))
    }
}

/// Unified multi-line prompt editor with an inline placeholder when empty.
struct PromptTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 110)
                .padding(4)
            if text.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Design.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).stroke(Color(nsColor: .separatorColor).opacity(0.4)))
    }
}
