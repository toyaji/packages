// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreImage
import Foundation
import ImageIO

/// Adds an ISO 21496-1 gain map to a photo, so that it shows as HDR on HDR displays.
///
/// With an HLG preview, some devices deliver photos without a gain map. The gain map is then made
/// from the 10-bit HLG video frame taken at the shutter: the photo stays the SDR base image, and
/// the frame gives the HDR rendition.
enum HDRPhotoGainMap {
  /// The largest difference between the photo and frame aspect ratios that still lets the frame
  /// be scaled onto the photo.
  private static let aspectRatioTolerance: CGFloat = 0.01

  /// Returns whether `data` already contains an Apple or ISO gain map.
  static func containsGainMap(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
      != nil
    {
      return true
    }
    if #available(iOS 18.0, macOS 15.0, *) {
      return CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }
    return false
  }

  /// Returns `photo` with an ISO gain map made from `hdrFrame`, keeping the photo's pixels and
  /// metadata, or nil if it cannot be made.
  ///
  /// `hdrFrame` must show the same scene as the photo, upright as displayed (the video connection
  /// rotates its buffers), while the photo's pixels keep the sensor orientation and an orientation
  /// property.
  static func addingGainMap(
    to photo: Data, hdrFrame: CVPixelBuffer, context: CIContext
  ) -> Data? {
    guard #available(iOS 18.0, macOS 15.0, *),
      let source = CGImageSourceCreateWithData(photo as CFData, nil),
      let type = CGImageSourceGetType(source),
      let sdr = CIImage(data: photo),
      let colorSpace = sdr.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)
    else {
      return nil
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation =
      (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap {
        CGImagePropertyOrientation(rawValue: $0)
      } ?? .up

    // Brings the upright frame back to the photo's sensor orientation.
    var hdr = CIImage(cvPixelBuffer: hdrFrame).oriented(inverse(of: orientation))
    let photoAspect = sdr.extent.width / sdr.extent.height
    let frameAspect = hdr.extent.width / hdr.extent.height
    guard abs(photoAspect - frameAspect) / photoAspect <= aspectRatioTolerance else { return nil }
    hdr = hdr.transformed(
      by: CGAffineTransform(translationX: -hdr.extent.minX, y: -hdr.extent.minY)
        .concatenating(
          CGAffineTransform(
            scaleX: sdr.extent.width / hdr.extent.width,
            y: sdr.extent.height / hdr.extent.height)))

    // Core Image reads the HLG frame as BT.2100 display light with BT.2408 reference white (203
    // cd/m2) at 1.0, the same values the HLG preview shows. The frame is used unscaled, so the
    // photo's HDR rendition equals the preview.
    // Core Image computes the gain map from the ratio of the HDR image to the SDR image. Only the
    // gain map of this intermediate file is used, so its format does not matter.
    guard
      let withGainMap = context.jpegRepresentation(
        of: sdr, colorSpace: colorSpace, options: [.hdrImage: hdr]),
      let gainMapSource = CGImageSourceCreateWithData(withGainMap as CFData, nil),
      let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        gainMapSource, 0, kCGImageAuxiliaryDataTypeISOGainMap)
    else {
      return nil
    }

    // The photo is copied as is, and only the gain map is added.
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    CGImageDestinationAddAuxiliaryDataInfo(
      destination, kCGImageAuxiliaryDataTypeISOGainMap, gainMap)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  /// The orientation that undoes `orientation`.
  static func inverse(of orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .right: return .left
    case .left: return .right
    default: return orientation
    }
  }
}
