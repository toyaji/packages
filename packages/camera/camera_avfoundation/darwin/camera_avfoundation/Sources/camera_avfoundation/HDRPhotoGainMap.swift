// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import CoreImage
import CoreImage.CIFilterBuiltins
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

    // The HLG frame puts diffuse white above SDR white, so its midtones are matched to the photo
    // first; otherwise the gain map would brighten the whole photo, not only its highlights.
    let scale = midtoneRatio(sdr: sdr, hdr: hdr, context: context)
    if scale > 0 {
      let filter = CIFilter.colorMatrix()
      filter.inputImage = hdr
      let k = CGFloat(1 / scale)
      filter.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
      filter.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
      filter.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
      if let matched = filter.outputImage {
        hdr = matched
      }
    }

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

  /// The median HDR-to-SDR luminance ratio over midtone pixels, or 0 if there are too few.
  ///
  /// Both images are compared small and in extended linear light. Dark and clipped SDR pixels are
  /// left out, since their ratio says nothing about exposure.
  static func midtoneRatio(sdr: CIImage, hdr: CIImage, context: CIContext) -> Float {
    let side: CGFloat = 64
    let scale = side / max(sdr.extent.width, sdr.extent.height)
    let width = Int((sdr.extent.width * scale).rounded())
    let height = Int((sdr.extent.height * scale).rounded())
    guard width > 0, height > 0,
      let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    else { return 0 }
    func render(_ image: CIImage) -> [Float] {
      var pixels = [Float](repeating: 0, count: width * height * 4)
      context.render(
        image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), toBitmap: &pixels,
        rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBAf, colorSpace: linear)
      return pixels
    }
    let sdrPixels = render(sdr)
    let hdrPixels = render(hdr)
    var ratios: [Float] = []
    for i in stride(from: 0, to: sdrPixels.count, by: 4) {
      let s = 0.2126 * sdrPixels[i] + 0.7152 * sdrPixels[i + 1] + 0.0722 * sdrPixels[i + 2]
      let h = 0.2126 * hdrPixels[i] + 0.7152 * hdrPixels[i + 1] + 0.0722 * hdrPixels[i + 2]
      if s > 0.02 && s < 0.8 && h > 0 {
        ratios.append(h / s)
      }
    }
    guard ratios.count >= width * height / 10 else { return 0 }
    ratios.sort()
    return ratios[ratios.count / 2]
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
