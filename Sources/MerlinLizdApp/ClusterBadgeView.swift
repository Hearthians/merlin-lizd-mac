import SwiftUI

struct ClusterBadgeView: View {
    let presentation: ClusterPresentation

    var body: some View {
        Text(presentation.shortCode.uppercased())
            .font(.caption2.monospaced().weight(.bold))
            .foregroundStyle(Color.indigo)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.indigo.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.indigo.opacity(0.2), lineWidth: 0.5)
            }
            .fixedSize()
            .help(presentation.helpText)
            .accessibilityLabel(presentation.helpText)
    }
}
