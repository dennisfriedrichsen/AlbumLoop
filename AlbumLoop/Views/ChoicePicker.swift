import SwiftUI

/// A settings row that opens a list of options, like a navigation-style `Picker`.
///
/// tvOS's own `Picker` only goes back when the selection changes, so pressing select
/// on the option that's already checked does nothing. Here, choosing any option —
/// including the current one — sets it and returns to the previous screen.
struct ChoicePicker<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    init(
        _ title: String,
        selection: Binding<Value>,
        options: [Value],
        label: @escaping (Value) -> String
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        NavigationLink {
            ChoiceList(title: title, options: options, selection: $selection, label: label)
        } label: {
            LabeledContent(title) {
                Text(label(selection))
            }
        }
    }
}

private struct ChoiceList<Value: Hashable>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    var body: some View {
        List(options, id: \.self) { option in
            Button {
                selection = option
                dismiss()
            } label: {
                HStack {
                    Text(label(option))
                    Spacer()
                    if option == selection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .focused($focused, equals: option)
        }
        .navigationTitle(title)
        // Start on the current option so pressing select right away keeps it.
        .defaultFocus($focused, selection)
    }
}
