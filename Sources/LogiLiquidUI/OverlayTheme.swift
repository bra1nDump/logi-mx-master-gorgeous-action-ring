import LogiLiquidCore
import SwiftUI

/// The standalone visual language for the native glass overlay.
public enum OverlayTheme {
  // Violet-to-pink accent family.
  public static let violet = Color(red: 0x8b / 255, green: 0x7c / 255, blue: 0xf7 / 255)
  public static let violetStrong = Color(red: 0xa8 / 255, green: 0x9b / 255, blue: 0xff / 255)
  public static let pink = Color(red: 0xf4 / 255, green: 0x72 / 255, blue: 0xb6 / 255)
  public static let text = Color(red: 0xed / 255, green: 0xea / 255, blue: 0xf2 / 255)
  public static let textMuted = Color(red: 0xa5 / 255, green: 0xa0 / 255, blue: 0xb0 / 255)

  /// Diameter of a resting target bubble.
  public static let targetBubbleDiameter = CGFloat(
    RingInteractionProfile.defaultTargetBubbleRadius * 2
  )
  /// The center bubble is exactly 20% smaller than a target bubble.
  public static let movingBubbleDiameter = CGFloat(
    RingInteractionProfile.defaultMovingBubbleRadius * 2
  )
  /// Point size for a target's SF Symbol.
  public static let symbolPointSize: CGFloat = 21
  /// Monochrome application templates are slightly larger than SF Symbols so
  /// intricate brand marks retain the same perceived visual weight.
  public static let applicationTemplateIconSize: CGFloat = 25

  /// The violet→pink brand gradient used to tint the selected target and the
  /// metaball bridge.
  public static let brandGradient = LinearGradient(
    colors: [violetStrong, pink],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  /// Interruptible spring for bubble motion and fusion. Interruptible by default
  /// in SwiftUI, so a mid-flight gesture retargets smoothly.
  public static let motionSpring = Animation.spring(response: 0.28, dampingFraction: 0.74)

  /// The backend holds the latched frame for 220 ms. This high-damping spring
  /// completes its suction in 160 ms, leaving the fused state visibly settled
  /// before the terminal frame hides the overlay.
  public static let latchSpring = Animation.spring(duration: 0.16, bounce: 0.05)

  public static let dismissalDuration = RingInteractionTiming.overlayDismissalDuration
  public static let dismissalAnimation = Animation.easeOut(duration: dismissalDuration)

  /// Entry is intentionally almost immediate and changes opacity only. The
  /// interaction geometry is full-size and in its final position from frame one.
  public static let presentationDuration: TimeInterval = 0.06
  public static let presentationAnimation = Animation.easeOut(duration: presentationDuration)

  /// Selection lighting ramps with Core's approach progress: the nearer the
  /// moving bubble gets to its target, the stronger the tint. The target and
  /// the moving bubble share this ramp, so both light up at the same speed.
  /// `selectionTint(0)` is exactly the resting `violet` tint at 0.30 opacity.
  public static func selectionTint(progress: Double) -> Color {
    let clamped = min(max(progress, 0), 1)
    func lerp(_ a: Double, _ b: Double) -> Double { a + ((b - a) * clamped) }
    return Color(
      red: lerp(0x8b, 0xa8) / 255,
      green: lerp(0x7c, 0x9b) / 255,
      blue: lerp(0xf7, 0xff) / 255
    )
    .opacity(lerp(0.30, 0.55))
  }
}
