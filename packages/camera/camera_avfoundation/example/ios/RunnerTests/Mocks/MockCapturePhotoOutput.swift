// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

@testable import camera_avfoundation

/// Mock implementation of `CapturePhotoOutput` protocol which allows injecting a custom
/// implementation.
final class MockCapturePhotoOutput: NSObject, CapturePhotoOutput {
  var avOutput = AVCapturePhotoOutput()
  var availablePhotoCodecTypes: [AVVideoCodecType] = []
  var isHighResolutionCaptureEnabled = false
  var supportedFlashModes: [AVCaptureDevice.FlashMode] = []

  // [Zelly patch] Plain stubs, not backed by `avOutput` — setting
  // `maxPhotoDimensions` on a real, unconnected `AVCapturePhotoOutput`
  // throws NSInvalidArgumentException, which a test double must not do.
  @available(iOS 16.0, *)
  var maxPhotoDimensions: CMVideoDimensions {
    get { _maxPhotoDimensions }
    set { _maxPhotoDimensions = newValue }
  }
  private var _maxPhotoDimensions = CMVideoDimensions(width: 0, height: 0)

  @available(iOS 17.0, *)
  var isZeroShutterLagSupported: Bool {
    get { _isZeroShutterLagSupported }
    set { _isZeroShutterLagSupported = newValue }
  }
  private var _isZeroShutterLagSupported = false

  @available(iOS 17.0, *)
  var isZeroShutterLagEnabled: Bool {
    get { _isZeroShutterLagEnabled }
    set { _isZeroShutterLagEnabled = newValue }
  }
  private var _isZeroShutterLagEnabled = false

  @available(iOS 17.0, *)
  var isResponsiveCaptureSupported: Bool {
    get { _isResponsiveCaptureSupported }
    set { _isResponsiveCaptureSupported = newValue }
  }
  private var _isResponsiveCaptureSupported = false

  @available(iOS 17.0, *)
  var isResponsiveCaptureEnabled: Bool {
    get { _isResponsiveCaptureEnabled }
    set { _isResponsiveCaptureEnabled = newValue }
  }
  private var _isResponsiveCaptureEnabled = false

  @available(iOS 17.0, *)
  var isFastCapturePrioritizationSupported: Bool {
    get { _isFastCapturePrioritizationSupported }
    set { _isFastCapturePrioritizationSupported = newValue }
  }
  private var _isFastCapturePrioritizationSupported = false

  @available(iOS 17.0, *)
  var isFastCapturePrioritizationEnabled: Bool {
    get { _isFastCapturePrioritizationEnabled }
    set { _isFastCapturePrioritizationEnabled = newValue }
  }
  private var _isFastCapturePrioritizationEnabled = false

  // Stub that is called when the corresponding public method is called.
  var capturePhotoWithSettingsStub:
    ((_ settings: AVCapturePhotoSettings, _ delegate: AVCapturePhotoCaptureDelegate) -> Void)?

  // Stub that is called when the corresponding public method is called.
  var connectionWithMediaTypeStub: ((_ mediaType: AVMediaType) -> CaptureConnection?)?

  func capturePhoto(with settings: AVCapturePhotoSettings, delegate: AVCapturePhotoCaptureDelegate)
  {
    capturePhotoWithSettingsStub?(settings, delegate)
  }

  func connection(with mediaType: AVMediaType) -> CaptureConnection? {
    return connectionWithMediaTypeStub?(mediaType)
  }
}
