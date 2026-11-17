// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

/// Determines the video dimensions (width and height) for a given capture device format.
/// Used in tests to mock CMVideoFormatDescriptionGetDimensions.
typealias VideoDimensionsConverter = (CaptureDeviceFormat) -> CMVideoDimensions

enum FormatUtils {
  /// The pixel format of the 10-bit formats used for HLG capture (`x420`).
  static let hlgPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

  /// Returns whether the format is 10-bit (`x420`) and supports the HLG BT.2020 color space.
  static func isHLGCapable(_ format: CaptureDeviceFormat) -> Bool {
    guard #available(iOS 14.1, *) else { return false }
    return CMFormatDescriptionGetMediaSubType(format.formatDescription) == hlgPixelFormat
      && format.flutterSupportedColorSpaces.contains(.HLG_BT2020)
  }

  /// Returns whether the format supports the HLG BT.2020 color space, which only 10-bit formats do.
  static func supportsHLGColorSpace(_ format: CaptureDeviceFormat) -> Bool {
    guard #available(iOS 14.1, *) else { return false }
    return format.flutterSupportedColorSpaces.contains(.HLG_BT2020)
  }

  /// Sets the HLG BT.2020 color space. Only reached after `isHLGCapable` returned true, which
  /// requires iOS 14.1.
  static func setHLGColorSpace(on device: CaptureDevice) {
    if #available(iOS 14.1, *) {
      device.activeColorSpace = .HLG_BT2020
    }
  }

  /// Returns the preview dynamic ranges the device supports. Always contains `.sdr`.
  static func supportedPreviewDynamicRanges(for device: CaptureDevice)
    -> [PlatformPreviewDynamicRange]
  {
    return device.flutterFormats.contains(where: isHLGCapable) ? [.sdr, .hlg10] : [.sdr]
  }

  /// The output size, in landscape, of the session presets that the resolution presets map to.
  /// Presets whose size depends on the device (such as `.high`) are not listed.
  static let sessionPresetSizes: [AVCaptureSession.Preset: (width: Int32, height: Int32)] = [
    .hd4K3840x2160: (3840, 2160),
    .hd1920x1080: (1920, 1080),
    .hd1280x720: (1280, 720),
    .vga640x480: (640, 480),
    .cif352x288: (352, 288),
  ]

  /// Finds the HLG-capable format to use instead of the SDR one the resolution preset chose.
  ///
  /// - With `.inputPriority` (the `max` preset), returns the largest HLG-capable format with the
  ///   aspect ratio of `reference`, the format the preset chose.
  /// - With a fixed-size session preset, returns an HLG-capable format of exactly that size, so the
  ///   requested resolution does not change.
  ///
  /// Returns nil if there is none, in which case the caller keeps the SDR format.
  static func findHLGFormat(
    for captureDevice: CaptureDevice,
    sessionPreset: AVCaptureSession.Preset,
    reference: CaptureDeviceFormat,
    videoDimensionsConverter: VideoDimensionsConverter
  ) -> CaptureDeviceFormat? {
    let candidates = captureDevice.flutterFormats.filter { format in
      guard isHLGCapable(format) else { return false }
      let size = videoDimensionsConverter(format)
      // Guard against the 1:1 formats of the iPhone 17 center stage sensor.
      return size.width != size.height
    }

    if sessionPreset == .inputPriority {
      let target = videoDimensionsConverter(reference)
      return
        candidates
        .filter {
          let size = videoDimensionsConverter($0)
          return Int64(size.width) * Int64(target.height) == Int64(size.height)
            * Int64(target.width)
        }
        .max {
          let a = videoDimensionsConverter($0)
          let b = videoDimensionsConverter($1)
          return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
        }
    }

    guard let target = sessionPresetSizes[sessionPreset] else { return nil }
    return candidates.first {
      let size = videoDimensionsConverter($0)
      return size.width == target.width && size.height == target.height
    }
  }

  /// Returns the pixel format to set in `AVCaptureVideoDataOutput.videoSettings`, or nil if none
  /// of the formats the output currently offers is usable. Setting a format that is not in
  /// `available` throws an exception. While a 10-bit HLG format is active, only `x420` and the
  /// `xv0` variants are offered, so the 10-bit format replaces the requested 8-bit one.
  static func resolveVideoPixelFormat(
    requested: FourCharCode,
    available: [FourCharCode],
    hlgActive: Bool
  ) -> FourCharCode? {
    if available.contains(requested) {
      return requested
    }
    if hlgActive && available.contains(hlgPixelFormat) {
      return hlgPixelFormat
    }
    return nil
  }

  /// Returns frame rate supported by format closest to targetFrameRate.
  static private func bestFrameRate(for format: CaptureDeviceFormat, targetFrameRate: Double)
    -> Double
  {
    var bestFrameRate: Double = 0
    var minDistance: Double = Double.greatestFiniteMagnitude

    for range in format.flutterVideoSupportedFrameRateRanges {
      let frameRate = min(
        max(targetFrameRate, Double(range.minFrameRate)), Double(range.maxFrameRate))
      let distance = abs(frameRate - targetFrameRate)
      if distance < minDistance {
        bestFrameRate = frameRate
        minDistance = distance
      }
    }

    return bestFrameRate
  }

  /// Finds format with same resolution as current activeFormat in captureDevice for which
  /// bestFrameRate returned frame rate closest to mediaSettings.framesPerSecond.
  /// Preferred are formats with the same subtype as current activeFormat. If `formatFilter` is given,
  /// only formats it accepts are considered. Returns this format
  /// and frame rate which bestFrameRate returned for that format.
  static func findBestFormat(
    for captureDevice: CaptureDevice,
    mediaSettings: PlatformMediaSettings,
    videoDimensionsConverter: VideoDimensionsConverter,
    formatFilter: ((CaptureDeviceFormat) -> Bool)? = nil
  ) -> (format: CaptureDeviceFormat, frameRate: Double) {
    let targetResolution = videoDimensionsConverter(captureDevice.flutterActiveFormat)
    let targetFrameRate = Double(mediaSettings.framesPerSecond ?? 0)
    let preferredSubType = CMFormatDescriptionGetMediaSubType(
      captureDevice.flutterActiveFormat.formatDescription)

    var bestFormat = captureDevice.flutterActiveFormat
    var resolvedBestFrameRate = bestFrameRate(for: bestFormat, targetFrameRate: targetFrameRate)
    var minDistance = abs(resolvedBestFrameRate - targetFrameRate)
    var isBestSubTypePreferred = true

    for format in captureDevice.flutterFormats {
      if let formatFilter = formatFilter, !formatFilter(format) {
        continue
      }
      let resolution = videoDimensionsConverter(format)
      if resolution.width != targetResolution.width || resolution.height != targetResolution.height
      {
        continue
      }

      let frameRate = bestFrameRate(for: format, targetFrameRate: targetFrameRate)
      let distance = abs(frameRate - targetFrameRate)
      let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
      let isSubTypePreferred = subType == preferredSubType

      if distance < minDistance
        || (distance == minDistance && isSubTypePreferred && !isBestSubTypePreferred)
      {
        bestFormat = format
        resolvedBestFrameRate = frameRate
        minDistance = distance
        isBestSubTypePreferred = isSubTypePreferred
      }
    }

    return (bestFormat, resolvedBestFrameRate)
  }

  /// The length of the shorter side that a resolution preset asks for within an aspect ratio, or
  /// nil for the highest resolution.
  static func shortSide(for preset: PlatformResolutionPreset) -> Int32? {
    switch preset {
    case .low: return 240
    case .medium: return 480
    case .high: return 720
    case .veryHigh: return 1080
    case .ultraHigh: return 2160
    case .max: return nil
    }
  }

  /// Returns whether `dimensions` have the given aspect ratio, in either orientation.
  static func matches(_ dimensions: CMVideoDimensions, _ aspectRatio: PlatformCameraAspectRatio)
    -> Bool
  {
    let (long, short): (Int64, Int64) =
      aspectRatio == .ratio4x3 ? (4, 3) : (16, 9)
    let width = Int64(max(dimensions.width, dimensions.height))
    let height = Int64(min(dimensions.width, dimensions.height))
    return width * short == height * long
  }

  /// Returns the formats of `captureDevice` for an aspect ratio and a resolution preset, best
  /// first, or an empty array when the device has no format with that aspect ratio.
  ///
  /// The formats have the aspect ratio and are HLG formats with `useHLG`, or formats without the
  /// HLG color space otherwise. Among them, the video size is the smallest whose shorter side is at
  /// least the preset's (the largest if none is, or for `max`). All returned formats have that
  /// size, ordered by the largest photo they can take.
  static func findAspectRatioFormats(
    for captureDevice: CaptureDevice,
    aspectRatio: PlatformCameraAspectRatio,
    preset: PlatformResolutionPreset,
    useHLG: Bool,
    videoDimensionsConverter: VideoDimensionsConverter
  ) -> [CaptureDeviceFormat] {
    let candidates = captureDevice.flutterFormats.filter { format in
      guard useHLG ? isHLGCapable(format) : !supportsHLGColorSpace(format) else { return false }
      return matches(videoDimensionsConverter(format), aspectRatio)
    }
    func shortSide(of format: CaptureDeviceFormat) -> Int32 {
      let size = videoDimensionsConverter(format)
      return min(size.width, size.height)
    }
    let sizes = Set(candidates.map(shortSide(of:))).sorted()
    guard let largest = sizes.last else { return [] }
    let target = FormatUtils.shortSide(for: preset).flatMap { minimum in
      sizes.first { $0 >= minimum }
    }
    let chosenSize = target ?? largest

    func photoPixels(_ format: CaptureDeviceFormat) -> Int64 {
      guard #available(iOS 16.0, *) else { return 0 }
      return format.supportedMaxPhotoDimensions
        .map { Int64($0.width) * Int64($0.height) }
        .max() ?? 0
    }
    // A stable sort keeps the device's order among formats that take the same photo size.
    return candidates.enumerated()
      .filter { shortSide(of: $0.element) == chosenSize }
      .sorted {
        let (lhs, rhs) = (photoPixels($0.element), photoPixels($1.element))
        return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
      }
      .map(\.element)
  }
}
