//
//  RoomNameSheet.swift
//  Hangs
//
//  #212: the name the others see, asked from a host without an account name
//  or changed by a guest in the lobby.
//

import SwiftUI

struct RoomNameSheet: View {
    @State private var name: String
    @FocusState private var focused: Bool
    let title: LocalizedStringKey
    let onSave: (String) -> Void

    init(title: LocalizedStringKey, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        _name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            Text(title)
                .font(.hangsHeading)
                .foregroundStyle(Theme.Hangs.Colors.ink)
            TextField("Your name", text: $name)
                .font(.hangsBodyLG)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(save)
                .padding(Theme.Hangs.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                        .fill(Theme.Hangs.Colors.bgInset)
                )
                .accessibilityIdentifier("room.name.field")
            Text("The other players see this name.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
            Spacer(minLength: 0)
            HangsPrimaryButton(title: "Save", action: save)
                .disabled(PlayerNameStore.cleaned(name) == nil)
                .accessibilityIdentifier("room.name.save")
        }
        .padding(Theme.Hangs.Spacing.lg)
        .background(Theme.Hangs.Colors.bgSheet)
        .onAppear { focused = true }
        .onChange(of: name) { _, new in
            if new.count > PlayerNameStore.maxLength { name = String(new.prefix(PlayerNameStore.maxLength)) }
        }
    }

    private func save() {
        guard let clean = PlayerNameStore.cleaned(name) else { return }
        onSave(clean)
    }
}
