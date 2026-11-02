import GitTreesCore
import SwiftUI

struct StashRecoveryDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let error: PresentableError

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(error.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(error.message)
                    if let detail = error.detail {
                        Text(detail).font(GitTreesUI.monospaced)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 440)
    }
}
