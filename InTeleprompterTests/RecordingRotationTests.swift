import CoreGraphics
import Testing
@testable import InTeleprompter

struct RecordingRotationTests {
    /// Older iPhones, and the back cameras on all of them, deliver the
    /// sensor's frames unturned: the coordinator's angle is the whole turn.
    @Test func framesDeliveredAsTheSensorSeesThem() {
        #expect(CameraManager.recordingRotation(horizonAngle: 90, framesRotatedBy: 0) == 90)
        #expect(CameraManager.recordingRotation(horizonAngle: 0, framesRotatedBy: 0) == 0)
        #expect(CameraManager.recordingRotation(horizonAngle: 180, framesRotatedBy: 0) == 180)
    }

    /// The iPhone 18 Pro Max's front camera is upright as mounted (0° in
    /// portrait) but delivers frames already turned 270°, which recorded
    /// sideways takes until this was accounted for.
    @Test func framesTheCameraAlreadyTurned() {
        #expect(CameraManager.recordingRotation(horizonAngle: 0, framesRotatedBy: 270) == 90)    // portrait
        #expect(CameraManager.recordingRotation(horizonAngle: 90, framesRotatedBy: 270) == 180)  // landscape, port on the left
        #expect(CameraManager.recordingRotation(horizonAngle: 270, framesRotatedBy: 270) == 0)   // landscape, port on the right
        #expect(CameraManager.recordingRotation(horizonAngle: 180, framesRotatedBy: 270) == 270) // upside down
    }
}
