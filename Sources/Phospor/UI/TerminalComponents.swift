import SwiftUI

// MARK: - Terminal Panel (mirrors mainframe's TerminalPanel)

struct TerminalPanel<Content: View>: View {
  let header: String?
  @ViewBuilder let content: () -> Content

  init(header: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.header = header
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let header {
        Text("► \(header.uppercased())")
          .font(Theme.mono(12, weight: .bold))
          .kerning(1)
          .foregroundStyle(Theme.primary)
          .padding(.bottom, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .overlay(
            Rectangle()
              .fill(Theme.primary)
              .frame(height: 1),
            alignment: .bottom
          )
          .padding(.bottom, 12)
      }
      content()
    }
    .padding(15)
    .background(Theme.panelBackground)
    .overlay(
      Rectangle().stroke(Theme.primary, lineWidth: Theme.panelBorder)
    )
    .shadow(color: Theme.primary.opacity(0.25), radius: Theme.glowRadius)
  }
}

// MARK: - Terminal Button (mirrors mainframe's TerminalButton)

enum TerminalButtonVariant {
  case primary, secondary, success, danger

  var color: Color {
    switch self {
    case .primary: return Theme.primary
    case .secondary: return Theme.secondary
    case .success: return Theme.success
    case .danger: return Theme.danger
    }
  }
}

struct TerminalButton: View {
  let title: String
  var variant: TerminalButtonVariant = .primary
  var icon: String? = nil
  var disabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
        }
        Text(title.uppercased())
          .font(Theme.mono(11, weight: .bold))
          .kerning(1)
      }
      .foregroundStyle(disabled ? Theme.dim : variant.color)
      .padding(.horizontal, 15)
      .padding(.vertical, 8)
      .frame(minWidth: 120)
      .overlay(
        Rectangle().stroke(disabled ? Theme.dim : variant.color, lineWidth: Theme.buttonBorder)
      )
    }
    .buttonStyle(.plain)
    .disabled(disabled)
  }
}

// MARK: - Terminal Row (toggle/list row used in the control panel)

struct TerminalRow<Trailing: View>: View {
  let icon: String
  let title: String
  let subtitle: String?
  @ViewBuilder let trailing: () -> Trailing
  let action: (() -> Void)?

  init(
    icon: String,
    title: String,
    subtitle: String? = nil,
    action: (() -> Void)? = nil,
    @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
  ) {
    self.icon = icon
    self.title = title
    self.subtitle = subtitle
    self.action = action
    self.trailing = trailing
  }

  var body: some View {
    Button(action: { action?() }) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(Theme.secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(title.uppercased())
            .font(Theme.mono(11, weight: .bold))
            .kerning(1)
            .foregroundStyle(Theme.primary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let subtitle {
            Text(subtitle)
              .font(Theme.mono(9))
              .foregroundStyle(Theme.muted)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        trailing()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(
        Rectangle().stroke(Theme.dim, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Pill (small status badge)

struct TerminalPill: View {
  let text: String
  var color: Color = Theme.danger

  var body: some View {
    Text(text.uppercased())
      .font(Theme.mono(9, weight: .bold))
      .kerning(1)
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .overlay(Rectangle().stroke(color, lineWidth: 1))
  }
}
