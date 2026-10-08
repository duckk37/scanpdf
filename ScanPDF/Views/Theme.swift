import SwiftUI

enum Theme {
    static let ink = Color(red: 0.07, green: 0.16, blue: 0.22)
    static let teal = Color(red: 0.02, green: 0.48, blue: 0.44)
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let muted = Color.secondary
}

struct ToolTile: View {
    let title: String
    let subtitle: String
    let icon: String
    var color: Color = Theme.teal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }
}
