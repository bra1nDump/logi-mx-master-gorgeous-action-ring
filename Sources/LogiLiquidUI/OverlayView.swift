import AppKit
import SwiftUI

/// The complete ring overlay: a set of glass target bubbles fanned around a
/// hidden origin, a moving center bubble driven by the cursor delta, and a
/// liquid metaball bridge that fuses the bubble into the selected target.
///
/// The view is pure presentation. It renders the model, reports a primary click
/// through `onPrimaryClick`, and never runs actions, haptics, or cursor changes.
public struct OverlayView: View {
  private let model: OverlayRenderModel
  /// Where the origin falls in this display's local top-left space.
  private let localOrigin: CGPoint
  private let onPrimaryClick: () -> Void
  /// Gym supplies this only for clock-free frame rendering. `nil` preserves the
  /// production on-appear animation exactly.
  private let presentationProgressOverride: CGFloat?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var glassNamespace
  @State private var presentationProgress: CGFloat = 0

  public init(
    model: OverlayRenderModel,
    localOrigin: CGPoint,
    presentationProgress: CGFloat? = nil,
    onPrimaryClick: @escaping () -> Void
  ) {
    self.model = model
    self.localOrigin = localOrigin
    presentationProgressOverride = presentationProgress
    self.onPrimaryClick = onPrimaryClick
  }

  public var body: some View {
    ZStack(alignment: .topLeading) {
      // A transparent catcher so a primary click anywhere dismisses before
      // overlap latch without stealing the frontmost app's activation.
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { onPrimaryClick() }

      metaballBridge
        .allowsHitTesting(false)

      GlassEffectContainer(spacing: 22) {
        ZStack(alignment: .topLeading) {
          ForEach(model.targets) { target in
            targetBubble(target)
          }
          movingBubble
        }
      }
      .allowsHitTesting(false)
    }
    .ignoresSafeArea()
    .animation(modelAnimation, value: model)
    .onAppear {
      guard presentationProgressOverride == nil else { return }
      guard !reduceMotion else {
        presentationProgress = 1
        return
      }
      presentationProgress = 0
      withAnimation(OverlayTheme.presentationSpring) {
        presentationProgress = 1
      }
    }
    .onChange(of: reduceMotion) { _, isReduced in
      if isReduced {
        presentationProgress = 1
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var modelAnimation: Animation? {
    guard !reduceMotion else { return nil }
    // Tracking must be geometrically exact: spring-smoothing the moving bubble
    // makes visible overlap lag Core's authoritative overlap threshold. Only the
    // post-latch suction snap is animated.
    return model.phase == .latched ? OverlayTheme.latchSpring : nil
  }

  private var effectivePresentationProgress: CGFloat {
    presentationProgressOverride ?? presentationProgress
  }

  private func targetBubble(_ target: OverlayTargetModel) -> some View {
    let tint = target.isCurrent ? OverlayTheme.violetStrong : OverlayTheme.violet
    return targetIcon(target.presentation)
      .frame(
        width: OverlayTheme.targetBubbleDiameter,
        height: OverlayTheme.targetBubbleDiameter
      )
      .glassEffect(
        .regular.tint(tint.opacity(target.isCurrent ? 0.55 : 0.30)).interactive(),
        in: Circle()
      )
      .glassEffectID(target.id, in: glassNamespace)
      .scaleEffect(
        (target.isCurrent && !reduceMotion ? OverlayTheme.selectedTargetScale : 1.0)
          * (0.72 + 0.28 * effectivePresentationProgress)
      )
      .opacity(effectivePresentationProgress)
      .accessibilityLabel(Text(target.presentation.label))
      .accessibilityAddTraits(target.isCurrent ? .isSelected : [])
      .position(
        // Center coordinates are authoritative interaction geometry and never
        // animate. Entry motion is limited to scale/opacity.
        x: localOrigin.x + target.offset.x,
        y: localOrigin.y + target.offset.y
      )
  }

  @ViewBuilder
  private func targetIcon(_ presentation: OverlayTargetPresentation) -> some View {
    switch presentation.icon {
    case .systemSymbol(let symbolName):
      Image(systemName: symbolName)
        .font(.system(size: OverlayTheme.symbolPointSize, weight: .semibold))
        .foregroundStyle(OverlayTheme.text)
    case .bundledTemplate(let resourceName, let fallbackSymbol):
      if let icon = Self.bundledTemplateIcon(named: resourceName) {
        Image(nsImage: icon)
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .foregroundStyle(OverlayTheme.text)
          .frame(
            width: OverlayTheme.applicationTemplateIconSize,
            height: OverlayTheme.applicationTemplateIconSize
          )
      } else {
        Image(systemName: fallbackSymbol)
          .font(.system(size: OverlayTheme.symbolPointSize, weight: .semibold))
          .foregroundStyle(OverlayTheme.text)
      }
    }
  }

  private static func bundledTemplateIcon(named resourceName: String) -> NSImage? {
    guard
      let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = true
    return image
  }

  private var movingBubble: some View {
    Circle()
      .fill(Color.clear)
      .frame(
        width: OverlayTheme.movingBubbleDiameter,
        height: OverlayTheme.movingBubbleDiameter
      )
      .glassEffect(.regular.tint(OverlayTheme.violet.opacity(0.30)).interactive(), in: Circle())
      .glassEffectID("moving-bubble", in: glassNamespace)
      .position(
        x: localOrigin.x + model.bubbleOffset.x,
        y: localOrigin.y + model.bubbleOffset.y
      )
  }

  @ViewBuilder private var metaballBridge: some View {
    if let current = model.targets.first(where: { $0.id == model.currentTargetID }) {
      AnimatedMetaballBridge(
        bubbleCenter: CGPoint(
          x: localOrigin.x + model.bubbleOffset.x,
          y: localOrigin.y + model.bubbleOffset.y
        ),
        targetCenter: CGPoint(
          x: localOrigin.x + current.offset.x,
          y: localOrigin.y + current.offset.y
        ),
        mergeProgress: CGFloat(model.mergeProgress)
      )
    }
  }
}

/// An animatable canvas keeps the liquid neck attached to the moving bubble
/// throughout the latched snap. A plain `Canvas` would receive the final model
/// immediately while only the bubble's `.position` interpolated, making the
/// bridge vanish before the suction animation finished.
private struct AnimatedMetaballBridge: View, @MainActor Animatable {
  var bubbleCenter: CGPoint
  var targetCenter: CGPoint
  var mergeProgress: CGFloat

  var animatableData:
    AnimatablePair<
      AnimatablePair<CGFloat, CGFloat>,
      AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>
    >
  {
    get {
      AnimatablePair(
        AnimatablePair(bubbleCenter.x, bubbleCenter.y),
        AnimatablePair(
          AnimatablePair(targetCenter.x, targetCenter.y),
          mergeProgress
        )
      )
    }
    set {
      bubbleCenter = CGPoint(x: newValue.first.first, y: newValue.first.second)
      targetCenter = CGPoint(x: newValue.second.first.first, y: newValue.second.first.second)
      mergeProgress = newValue.second.second
    }
  }

  var body: some View {
    Canvas { context, _ in
      guard
        let bridge = MetaballGeometry.bridge(
          centerA: bubbleCenter,
          radiusA: OverlayTheme.movingBubbleDiameter / 2,
          centerB: targetCenter,
          radiusB: OverlayTheme.targetBubbleDiameter / 2,
          mergeProgress: Double(mergeProgress)
        ),
        bridge.isConnected
      else { return }

      let dx = targetCenter.x - bubbleCenter.x
      let dy = targetCenter.y - bubbleCenter.y
      let distance = max((dx * dx + dy * dy).squareRoot(), 1e-6)
      let axis = CGPoint(x: dx / distance, y: dy / distance)
      let capA = CGPoint(
        x: bubbleCenter.x - axis.x * (OverlayTheme.movingBubbleDiameter / 2),
        y: bubbleCenter.y - axis.y * (OverlayTheme.movingBubbleDiameter / 2)
      )
      let capB = CGPoint(
        x: targetCenter.x + axis.x * (OverlayTheme.targetBubbleDiameter / 2),
        y: targetCenter.y + axis.y * (OverlayTheme.targetBubbleDiameter / 2)
      )

      var path = Path()
      path.move(to: bridge.contactA1)
      path.addCurve(to: bridge.contactB1, control1: bridge.controlA, control2: bridge.controlB)
      path.addQuadCurve(to: bridge.contactB2, control: capB)
      path.addCurve(to: bridge.contactA2, control1: bridge.controlB, control2: bridge.controlA)
      path.addQuadCurve(to: bridge.contactA1, control: capA)
      path.closeSubpath()

      context.fill(
        path,
        with: .linearGradient(
          Gradient(colors: [
            OverlayTheme.violetStrong.opacity(0.55),
            OverlayTheme.violet.opacity(0.48),
          ]),
          startPoint: bubbleCenter,
          endPoint: targetCenter
        )
      )
    }
  }
}
