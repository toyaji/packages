// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

/// A protocol which is a direct passthrough to `AVFrameRateRange`. It exists to allow replacing
/// `AVFrameRateRange` in tests as it has no public initializer.
protocol FrameRateRange: NSObjectProtocol {
  var minFrameRate: Float64 { get }
  var maxFrameRate: Float64 { get }
}

/// A protocol which is a direct passthrough to `AVCaptureDeviceFormat`. It exists to allow
/// replacing `AVCaptureDeviceFormat` in tests as it has no public initializer.
protocol CaptureDeviceFormat: NSObjectProtocol {
  /// The underlying `AVCaptureDeviceFormat` instance. This exists so that the format
  /// can be extracted when setting the active format on a device.
  var avFormat: AVCaptureDevice.Format { get }

  var formatDescription: CMFormatDescription { get }
  var flutterVideoSupportedFrameRateRanges: [FrameRateRange] { get }

  // [Zelly patch] Exposed directly on the protocol (rather than requiring
  // `.avFormat`, which test doubles can't safely implement — see
  // MockCaptureDeviceFormat) so shutter-speed candidate format selection
  // (`configureActiveFormatForShutterSpeed` in DefaultCamera.swift) is
  // testable. Names match the real `AVCaptureDevice.Format` API exactly so
  // the real-device extension below needs no extra implementation. Both are
  // iOS 16+ APIs, hence the availability annotation (this plugin's minimum
  // deployment target is iOS 13).
  @available(iOS 16.0, *)
  var isHighPhotoQualitySupported: Bool { get }
  @available(iOS 16.0, *)
  var supportedMaxPhotoDimensions: [CMVideoDimensions] { get }
}

extension AVFrameRateRange: FrameRateRange {}

extension AVCaptureDevice.Format: CaptureDeviceFormat {
  var avFormat: AVCaptureDevice.Format { self }

  var flutterVideoSupportedFrameRateRanges: [FrameRateRange] { videoSupportedFrameRateRanges }
}
