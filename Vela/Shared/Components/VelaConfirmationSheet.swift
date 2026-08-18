import SwiftUI

struct VelaConfirmationSheet<Details: View>: View {
    let title: String
    let message: String
    let confirmTitle: String
    var confirmRole: ButtonRole? = .destructive
    let onConfirm: () -> Void
    let onCancel: () -> Void
    private let details: Details

    init(
        title: String,
        message: String,
        confirmTitle: String,
        confirmRole: ButtonRole? = .destructive,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder details: () -> Details
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.confirmRole = confirmRole
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.details = details()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.large) {
            VStack(alignment: .leading, spacing: VelaSpacing.small) {
                Text(verbatim: title)
                    .font(VelaTypography.pageTitle)
                Text(verbatim: message)
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            details

            HStack {
                Spacer()
                Button(
                    VelaL10n.string("common.cancel", defaultValue: "Cancel"),
                    role: .cancel,
                    action: onCancel
                )
                    .keyboardShortcut(.cancelAction)
                Button(role: confirmRole, action: onConfirm) {
                    Text(verbatim: confirmTitle)
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VelaSpacing.large)
        .frame(minWidth: 420, idealWidth: 480)
    }
}

extension VelaConfirmationSheet where Details == EmptyView {
    init(
        title: String,
        message: String,
        confirmTitle: String,
        confirmRole: ButtonRole? = .destructive,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.confirmRole = confirmRole
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        details = EmptyView()
    }
}
