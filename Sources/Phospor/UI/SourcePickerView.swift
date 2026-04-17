import AppKit
import ScreenCaptureKit
import SwiftUI

struct SourcePickerView: View {
  private enum LoadState {
    case loading
    case needsPermission
    case error(String)
    case loaded(displays: [SCDisplay], windows: [SCWindow])
  }

  @State private var loadState: LoadState

  var onSelect: (CaptureSource) -> Void
  var onClose: () -> Void

  init(
    prefetchedSources: (displays: [SCDisplay], windows: [SCWindow])? = nil,
    onSelect: @escaping (CaptureSource) -> Void,
    onClose: @escaping () -> Void
  ) {
    self.onSelect = onSelect
    self.onClose = onClose
    if let pre = prefetchedSources {
      _loadState = State(initialValue: .loaded(displays: pre.displays, windows: pre.windows))
    } else {
      _loadState = State(initialValue: .loading)
    }
  }

  var body: some View {
    TerminalPanel(header: "SELECT SOURCE") {
      VStack(alignment: .leading, spacing: 12) {
        content

        HStack {
          Spacer()
          TerminalButton(title: "CLOSE", variant: .secondary, action: onClose)
        }
      }
      .frame(width: 360)
    }
    .padding(14)
    .background(Theme.background)
    .task {
      if case .loading = loadState {
        await load()
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch loadState {
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small).tint(Theme.primary)
        Text("LOADING...")
          .font(Theme.mono(10, weight: .bold))
          .kerning(1)
          .foregroundStyle(Theme.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

    case .needsPermission:
      permissionBlocked

    case .error(let text):
      VStack(alignment: .leading, spacing: 10) {
        Text("ERROR")
          .font(Theme.mono(10, weight: .bold))
          .kerning(1)
          .foregroundStyle(Theme.danger)
        Text(text)
          .font(Theme.mono(10))
          .foregroundStyle(Theme.muted)
          .fixedSize(horizontal: false, vertical: true)
        TerminalButton(title: "RETRY", variant: .primary) {
          Task { await load() }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

    case .loaded(let displays, let windows):
      listBody(displays: displays, windows: windows)
    }
  }

  private var permissionBlocked: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("► SCREEN RECORDING REQUIRED")
        .font(Theme.mono(10, weight: .bold))
        .kerning(1)
        .foregroundStyle(Theme.danger)

      Text("PHOSPOR NEEDS PERMISSION TO LIST DISPLAYS AND WINDOWS.")
        .font(Theme.mono(10))
        .foregroundStyle(Theme.primary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 4) {
        Text("STEPS:")
          .font(Theme.mono(9, weight: .bold))
          .kerning(1)
          .foregroundStyle(Theme.secondary)
        Text("1. OPEN SYSTEM SETTINGS BELOW")
        Text("2. REMOVE PHOSPOR FROM THE LIST IF PRESENT")
        Text("3. RELAUNCH PHOSPOR AND APPROVE THE PROMPT")
      }
      .font(Theme.mono(9))
      .foregroundStyle(Theme.muted)

      HStack(spacing: 8) {
        TerminalButton(title: "OPEN SETTINGS", variant: .primary) {
          openScreenRecordingSettings()
        }
        TerminalButton(title: "RECHECK", variant: .secondary) {
          Task { await load() }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func listBody(displays: [SCDisplay], windows: [SCWindow]) -> some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 14) {
        section(title: "DISPLAYS [\(displays.count)]") {
          if displays.isEmpty {
            emptyHint("NO DISPLAYS")
          } else {
            ForEach(displays, id: \.displayID) { d in
              let src = CaptureSource.display(d)
              TerminalRow(
                icon: "display",
                title: "DISPLAY \(d.displayID)",
                subtitle: "\(d.width)×\(d.height)",
                action: { onSelect(src) }
              ) {
                Image(systemName: "chevron.right")
                  .font(.system(size: 10, weight: .bold))
                  .foregroundStyle(Theme.secondary)
              }
            }
          }
        }

        section(title: "WINDOWS [\(windows.count)]") {
          if windows.isEmpty {
            emptyHint("NO WINDOWS")
          } else {
            ForEach(windows, id: \.windowID) { w in
              let src = CaptureSource.window(w)
              TerminalRow(
                icon: "macwindow",
                title: (w.title?.isEmpty == false ? w.title! : "UNTITLED"),
                subtitle: w.owningApplication?.applicationName ?? "—",
                action: { onSelect(src) }
              ) {
                Image(systemName: "chevron.right")
                  .font(.system(size: 10, weight: .bold))
                  .foregroundStyle(Theme.secondary)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 2)
    }
    .frame(minHeight: 200, maxHeight: 420)
  }

  @ViewBuilder
  private func section<Content: View>(title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text("► \(title)")
        .font(Theme.mono(10, weight: .bold))
        .kerning(1)
        .foregroundStyle(Theme.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func emptyHint(_ text: String) -> some View {
    Text(text)
      .font(Theme.mono(9))
      .foregroundStyle(Theme.muted)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(Rectangle().stroke(Theme.dim, lineWidth: 1))
  }

  // MARK: - Loading

  private func load() async {
    loadState = .loading

    // First, ask the OS for permission. If we don't have it, fail fast.
    let granted = ScreenCaptureManager.shared.requestScreenRecordingPermission()
    if !granted {
      loadState = .needsPermission
      return
    }

    do {
      let result = try await ScreenCaptureManager.shared.loadSources()
      loadState = .loaded(displays: result.displays, windows: result.windows)
    } catch {
      // SCK throws "user declined TCCs" when the cdhash mismatch trick
      // bites — surface it as a permission issue rather than a raw error.
      let nsError = error as NSError
      let msg = nsError.localizedDescription.lowercased()
      if msg.contains("declined") || msg.contains("not authorized") || msg.contains("permission") {
        loadState = .needsPermission
      } else {
        loadState = .error(nsError.localizedDescription)
      }
    }
  }

  private func openScreenRecordingSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    {
      NSWorkspace.shared.open(url)
    }
  }
}
