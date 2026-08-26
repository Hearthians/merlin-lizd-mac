import SwiftUI

struct StatusPill: View {
    let label: String
    let color: Color
    var symbol: String = "circle.fill"

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct MetricPill: View {
    let symbol: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        Label(value, systemImage: symbol)
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct SurfaceCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.65), lineWidth: 0.5)
        }
    }
}

struct MessageBanner: View {
    enum Kind {
        case info
        case warning
        case error

        var color: Color {
            switch self {
            case .info: .blue
            case .warning: .orange
            case .error: .red
            }
        }

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        Label(text, systemImage: kind.symbol)
            .font(.callout)
            .foregroundStyle(kind.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(kind.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}
