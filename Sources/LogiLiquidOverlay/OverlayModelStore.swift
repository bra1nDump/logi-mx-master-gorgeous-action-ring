import CoreGraphics
import LogiLiquidUI
import SwiftUI

/// The observable bridge between the `@MainActor` controller and the SwiftUI
/// overlay hosted in the panel. It carries only render state.
@MainActor
final class OverlayModelStore: ObservableObject {
  struct Snapshot {
    var isVisible = false
    var model: OverlayRenderModel?
    /// The origin in the current display's local top-left space.
    var localOrigin: CGPoint = .zero
  }

  /// A single published value keeps visibility, content, and placement atomic.
  /// In particular, a newly visible view can never render a frame at the old
  /// `.zero` origin before its real pointer origin arrives.
  @Published private(set) var snapshot = Snapshot()

  var localOrigin: CGPoint { snapshot.localOrigin }

  func update(isVisible: Bool, model: OverlayRenderModel?, localOrigin: CGPoint) {
    snapshot = Snapshot(isVisible: isVisible, model: model, localOrigin: localOrigin)
  }
}

/// Renders the overlay when the store says it is visible; otherwise a fully
/// transparent, non-interactive surface so the panel shows nothing when idle.
struct OverlayHostView: View {
  @ObservedObject var store: OverlayModelStore
  let onPrimaryClick: () -> Void

  var body: some View {
    ZStack {
      if let model = store.snapshot.model {
        OverlayView(
          model: model,
          localOrigin: store.snapshot.localOrigin,
          onPrimaryClick: onPrimaryClick
        )
        .opacity(store.snapshot.isVisible ? 1 : 0)
        .animation(
          OverlayTheme.dismissalAnimation,
          value: store.snapshot.isVisible
        )
        .allowsHitTesting(store.snapshot.isVisible)
      }
    }
  }
}
