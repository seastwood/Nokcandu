import Foundation

/// Motion from macOS's GameController framework, in SDL's axes (x right, y out of the face, z towards the player),
/// which the pad engine and the overlay use.
///
/// GameController's axes, held normally: x to the right, y up towards the triggers, z out of the face towards the
/// player. Its gravity points down (−1 g out of the face while the controller lies flat); SDL's accelerometer reads
/// the reaction (+1 g up). Without this, turning a Switch Pro or PlayStation controller reads as rolling, and the
/// overlay draws it lying back with its triggers away from you.
public enum GameControllerMotion {
    public static func gyro(_ x: Double, _ y: Double, _ z: Double) -> [Float] { [Float(x), Float(z), Float(-y)] }
    public static func acceleration(_ x: Double, _ y: Double, _ z: Double) -> [Float] { [Float(-x), Float(-z), Float(y)] }
}

/// Nokcandu's motion axes (the original Steam Controller's own: SDL's x, z, y), which controller decoders produce,
/// to SDL's (x pitch, y yaw, z roll), which the pad engine and the overlay take.
public enum MotionAxes {
    public static func sdl(gyro g: [Float], acceleration a: [Float]) -> ([Float], [Float]) {
        (g.count == 3 ? [g[0], g[2], g[1]] : g, a.count == 3 ? [a[0], a[2], a[1]] : a)
    }
}
