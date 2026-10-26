import SwiftUI

/// Click, then press a key combination. Escape cancels, Delete clears. Recording itself lives in
/// `ShortcutCenter`, so only one recorder can be armed and it stops when the window goes away.
struct ShortcutRecorder: View {
    @Environment(ShortcutCenter.self) private var shortcuts
    let action: ShortcutAction

    var body: some View {
        let isRecording = shortcuts.recordingAction == action
        let shortcut = shortcuts.shortcut(for: action)

        HStack(spacing: 6) {
            if let problem = shortcuts.problem, problem.action == action {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Button {
                isRecording ? shortcuts.endRecording() : shortcuts.beginRecording(action)
            } label: {
                Text(label(isRecording: isRecording, shortcut: shortcut))
                    .font(.system(size: 12, weight: shortcut == nil && !isRecording ? .regular : .medium))
                    .foregroundStyle(isRecording || shortcut != nil ? .primary : .secondary)
                    .frame(minWidth: 112)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(isRecording ? Color.accentColor.opacity(0.16) : .primary.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(isRecording ? Color.accentColor : .primary.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecording ? "Recording shortcut" : "Shortcut: \(label(isRecording: false, shortcut: shortcut))")

            Button("Clear", systemImage: "xmark.circle.fill") { shortcuts.clear(action) }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(shortcut == nil || isRecording ? 0 : 1)
                .disabled(shortcut == nil || isRecording)
        }
    }

    private func label(isRecording: Bool, shortcut: Shortcut?) -> String {
        if isRecording {
            return shortcuts.heldModifiers.isEmpty ? "Type shortcut…" : Shortcut.symbols(for: shortcuts.heldModifiers)
        }
        return shortcut?.displayString ?? "Record Shortcut"
    }
}
