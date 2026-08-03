// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import XCTest

@testable import camera_avfoundation

/// Includes test cases related to resolution presets setting operations for Camera class.
///
/// [Zelly patch] `setCaptureSessionPreset` (resolutionPreset-driven session/format
/// configuration) is no longer used on the no-fps path — replaced by
/// `configureActiveFormatForShutterSpeed` (D10), which always puts the video
/// session in `.inputPriority` and selects the active format by photo-quality
/// candidate ranking instead of by `resolutionPreset`. See
/// docs/camera/design/shutter-latency-final.md §3-2.
final class CameraSessionPresetsTests: XCTestCase {
  // [Zelly patch] There is intentionally no test here for the ZSL
  // candidate-selection/lockForConfiguration path itself:
  // `capturePhotoOutput` is hardcoded to a real `AVCapturePhotoOutput()` in
  // `DefaultCamera.init` (not injected via `CameraConfiguration`), so no test
  // can substitute `MockCapturePhotoOutput` before
  // `configureActiveFormatForShutterSpeed` runs during init. Assigning
  // `maxPhotoDimensions` on a real, session-disconnected AVCapturePhotoOutput
  // throws NSInvalidArgumentException in this harness. Making that path
  // testable would require adding a `capturePhotoOutputFactory` hook to
  // `CameraConfiguration`, which is out of scope here.
  func testConfigureActiveFormatForShutterSpeed_alwaysSetsInputPriorityRegardlessOfPreset() {
    for preset: PlatformResolutionPreset in [.max, .ultraHigh, .medium] {
      let expectation = self.expectation(
        description: "Expected .inputPriority preset set for \(preset)")

      let videoSessionMock = MockCaptureSession()
      videoSessionMock.canSetSessionPresetStub = { _ in true }
      videoSessionMock.setSessionPresetStub = { sessionPreset in
        if sessionPreset == .inputPriority {
          expectation.fulfill()
        }
      }

      let configuration = CameraTestUtils.createTestCameraConfiguration()
      configuration.videoCaptureSession = videoSessionMock
      configuration.mediaSettings = CameraTestUtils.createDefaultMediaSettings(
        resolutionPreset: preset)
      configuration.videoCaptureDeviceFactory = { _ in MockCaptureDevice() }

      let _ = CameraTestUtils.createTestCamera(configuration)

      waitForExpectations(timeout: 30, handler: nil)
    }
  }
}
