// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation
import Flutter
import ImageIO
import XCTest

@testable import camera_avfoundation

private let x420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
private let yuv420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

private func makeFormat(
  _ codecType: OSType, _ width: Int32, _ height: Int32,
  colorSpaces: [AVCaptureColorSpace] = [.sRGB]
) -> MockCaptureDeviceFormat {
  let format = MockCaptureDeviceFormat(codecType: codecType, width: width, height: height)
  format.flutterSupportedColorSpaces = colorSpaces
  return format
}

private func makeHLGFormat(_ width: Int32, _ height: Int32) -> MockCaptureDeviceFormat {
  return makeFormat(x420, width, height, colorSpaces: [.sRGB, .HLG_BT2020])
}

final class HDRPreviewTests: XCTestCase {
  private var activeFormat: CaptureDeviceFormat!

  private func makeDevice(formats: [MockCaptureDeviceFormat]) -> MockCaptureDevice {
    let device = MockCaptureDevice()
    device.flutterFormats = formats
    activeFormat = formats[0]
    device.activeFormatStub = { [unowned self] in self.activeFormat }
    device.setActiveFormatStub = { [unowned self] in self.activeFormat = $0 }
    return device
  }

  private func makeCamera(
    device: MockCaptureDevice,
    preset: PlatformResolutionPreset = .max,
    range: PlatformPreviewDynamicRange = .hlg10,
    session: MockCaptureSession = MockCaptureSession()
  ) -> DefaultCamera {
    let configuration = CameraTestUtils.createTestCameraConfiguration()
    configuration.videoCaptureDeviceFactory = { _ in device }
    // A real session keeps the preset it is given; the HLG format choice depends on it.
    session.setSessionPresetStub = { [unowned session] in session._sessionPreset = $0 }
    configuration.videoCaptureSession = session
    configuration.mediaSettings = PlatformMediaSettings(
      resolutionPreset: preset, framesPerSecond: nil, videoBitrate: nil, audioBitrate: nil,
      enableAudio: false, previewDynamicRange: range)
    return CameraTestUtils.createTestCamera(configuration)
  }

  private func dimensions(of format: CaptureDeviceFormat) -> CMVideoDimensions {
    return CMVideoFormatDescriptionGetDimensions(format.formatDescription)
  }

  // MARK: Supported ranges

  func testSupportedRanges_includesHLGOnlyForTenBitFormatWithHLGColorSpace() {
    let withHLG = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440)])
    XCTAssertEqual(FormatUtils.supportedPreviewDynamicRanges(for: withHLG), [.sdr, .hlg10])

    let tenBitWithoutHLG = makeDevice(formats: [makeFormat(x420, 1920, 1440)])
    XCTAssertEqual(FormatUtils.supportedPreviewDynamicRanges(for: tenBitWithoutHLG), [.sdr])

    let hlgColorSpaceOnEightBit = makeDevice(formats: [
      makeFormat(yuv420, 1920, 1440, colorSpaces: [.sRGB, .HLG_BT2020])
    ])
    XCTAssertEqual(FormatUtils.supportedPreviewDynamicRanges(for: hlgColorSpaceOnEightBit), [.sdr])

    XCTAssertEqual(
      FormatUtils.supportedPreviewDynamicRanges(for: MockCaptureDevice()), [.sdr])
  }

  func testPluginReturnsSupportedRangesOfTheNamedDevice() {
    let device = makeDevice(formats: [makeHLGFormat(1920, 1440)])
    let queue = DispatchQueue(label: "io.flutter.camera.captureSessionQueue")
    let plugin = CameraPlugin(
      registry: MockFlutterTextureRegistry(),
      messenger: MockFlutterBinaryMessenger(),
      globalAPI: MockGlobalEventApi(),
      deviceDiscoverer: MockCameraDeviceDiscoverer(),
      permissionManager: MockCameraPermissionManager(),
      deviceFactory: { _ in device },
      captureSessionFactory: { MockCaptureSession() },
      captureDeviceInputFactory: MockCaptureDeviceInputFactory(),
      captureSessionQueue: queue)
    let expectation = expectation(description: "completed")
    var ranges: [PlatformPreviewDynamicRange]?
    plugin.getSupportedPreviewDynamicRanges(cameraName: "camera") { result in
      ranges = self.assertSuccess(result)
      expectation.fulfill()
    }
    waitForExpectations(timeout: 5)
    XCTAssertEqual(ranges, [.sdr, .hlg10])
  }

  // MARK: Applying HLG

  func testHLGIsApplied_whenSupported() {
    let device = makeDevice(formats: [
      makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440), makeHLGFormat(3840, 2160),
    ])
    let session = MockCaptureSession()
    let camera = makeCamera(device: device, session: session)

    XCTAssertEqual(camera.previewDynamicRange, .hlg10)
    XCTAssertEqual(device.activeColorSpace, .HLG_BT2020)
    XCTAssertFalse(session.automaticallyConfiguresCaptureDeviceForWideColor)
    // The 4:3 HLG format is picked, not the 16:9 one that has more pixels.
    let size = dimensions(of: activeFormat)
    XCTAssertEqual(size.width, 1920)
    XCTAssertEqual(size.height, 1440)
  }

  func testFixedSizePresetUsesHLGFormatOfExactlyThatSize() {
    let device = makeDevice(formats: [
      makeFormat(yuv420, 1920, 1080), makeHLGFormat(1920, 1440), makeHLGFormat(3840, 2160),
      makeHLGFormat(1920, 1080),
    ])
    let camera = makeCamera(device: device, preset: .veryHigh)

    XCTAssertEqual(camera.previewDynamicRange, .hlg10)
    let size = dimensions(of: activeFormat)
    XCTAssertEqual(size.width, 1920)
    XCTAssertEqual(size.height, 1080)
  }

  func testFixedSizePresetStaysSDR_whenNoHLGFormatOfThatSize() {
    // The HLG formats are larger than 640x480, and using one would change the resolution.
    let device = makeDevice(formats: [
      makeFormat(yuv420, 1920, 1440), makeHLGFormat(1920, 1440), makeHLGFormat(1280, 720),
    ])
    let camera = makeCamera(device: device, preset: .medium)

    XCTAssertEqual(camera.previewDynamicRange, .sdr)
    XCTAssertEqual(device.activeColorSpace, .sRGB)
  }

  func testImageStreamingKeepsTheHDRSessionAsItIs() {
    let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440)])
    let session = MockCaptureSession()
    let camera = makeCamera(device: device, session: session)
    XCTAssertEqual(camera.previewDynamicRange, .hlg10)
    var reconfigured = false
    session.beginConfigurationStub = { reconfigured = true }
    session.stopRunningStub = { reconfigured = true }

    let started = expectation(description: "stream started")
    camera.startImageStream(
      with: MockFlutterBinaryMessenger(),
      imageStreamHandler: DefaultImageStreamHandler(captureSessionQueue: DispatchQueue.main),
      completion: { _ in started.fulfill() })
    waitForExpectations(timeout: 5)

    XCTAssertEqual(camera.previewDynamicRange, .hlg10)
    XCTAssertFalse(reconfigured)
  }

  func testFallsBackToSDR_whenNoHLGFormatExists() {
    let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024)])
    let session = MockCaptureSession()
    let camera = makeCamera(device: device, session: session)

    XCTAssertEqual(camera.previewDynamicRange, .sdr)
    XCTAssertEqual(device.activeColorSpace, .sRGB)
    XCTAssertTrue(session.automaticallyConfiguresCaptureDeviceForWideColor)
    XCTAssertEqual(dimensions(of: activeFormat).width, 4032)
  }

  func testFallsBackToSDR_whenHLGFormatNotWithSameAspectRatio() {
    let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(3840, 2160)])
    let camera = makeCamera(device: device)

    XCTAssertEqual(camera.previewDynamicRange, .sdr)
    XCTAssertEqual(dimensions(of: activeFormat).width, 4032)
  }

  func testFallsBackToSDR_whenColorSpaceMissingOrPixelFormatIsEightBit() {
    let noColorSpace = makeDevice(formats: [
      makeFormat(yuv420, 4032, 3024), makeFormat(x420, 1920, 1440),
    ])
    XCTAssertEqual(makeCamera(device: noColorSpace).previewDynamicRange, .sdr)

    let eightBit = makeDevice(formats: [
      makeFormat(yuv420, 4032, 3024),
      makeFormat(yuv420, 1920, 1440, colorSpaces: [.sRGB, .HLG_BT2020]),
    ])
    XCTAssertEqual(makeCamera(device: eightBit).previewDynamicRange, .sdr)
  }

  func testSDRRequestNeverTouchesHLGState() {
    let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440)])
    let session = MockCaptureSession()
    let camera = makeCamera(device: device, range: .sdr, session: session)

    XCTAssertEqual(camera.previewDynamicRange, .sdr)
    XCTAssertEqual(device.activeColorSpace, .sRGB)
    XCTAssertTrue(session.automaticallyConfiguresCaptureDeviceForWideColor)
  }

  func testPhotoOutputStartsWithTheSession_onlyForHLGRequest() throws {
    #if compiler(>=6.2)
      guard #available(iOS 26.0, macOS 26.0, *) else {
        throw XCTSkip("Deferred start requires iOS 26.")
      }
      let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440)])
      let hlgOutput = makeCamera(device: device).capturePhotoOutput.avOutput
      let sdrOutput = makeCamera(device: device, range: .sdr).capturePhotoOutput.avOutput
      guard hlgOutput.isDeferredStartSupported else {
        throw XCTSkip("Deferred start is not supported here.")
      }
      XCTAssertFalse(hlgOutput.isDeferredStartEnabled)
      XCTAssertTrue(sdrOutput.isDeferredStartEnabled)
    #else
      throw XCTSkip("Deferred start requires the iOS 26 SDK.")
    #endif
  }

  // MARK: HDR photo

  func testHdrPhotoIsSupportedOnlyWithAnHLGSession() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Requires iOS 18.") }
    let hlg = makeCamera(device: makeDevice(formats: [makeHLGFormat(1920, 1440)]), range: .hlg10)
    XCTAssertTrue(hlg.isHdrPhotoSupported())

    let sdr = makeCamera(device: makeDevice(formats: [makeHLGFormat(1920, 1440)]), range: .sdr)
    XCTAssertFalse(sdr.isHdrPhotoSupported())
  }

  /// A JPEG of `width`x`height` mid gray, with an orientation property.
  private func makeJPEG(_ width: Int, _ height: Int, orientation: CGImagePropertyOrientation)
    -> Data
  {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.displayP3)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(gray: 0.4, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(
      destination, context.makeImage()!,
      [
        kCGImagePropertyOrientation: orientation.rawValue,
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifLensModel: "test lens"
        ],
      ] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  /// A 10-bit HLG frame of `width`x`height` brighter than the SDR photo.
  private func makeHLGFrame(_ width: Int, _ height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let frame = buffer!
    CVPixelBufferLockBaseAddress(frame, [])
    for (plane, value) in [(0, UInt16(900) << 6), (1, UInt16(512) << 6)] {
      let base = CVPixelBufferGetBaseAddressOfPlane(frame, plane)!.assumingMemoryBound(
        to: UInt16.self)
      let count =
        CVPixelBufferGetBytesPerRowOfPlane(frame, plane) / 2
        * CVPixelBufferGetHeightOfPlane(frame, plane)
      base.update(repeating: value, count: count)
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    CVBufferSetAttachment(
      frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020,
      .shouldPropagate)
    CVBufferSetAttachment(
      frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG,
      .shouldPropagate)
    CVBufferSetAttachment(
      frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    return frame
  }

  /// Core Image in the iOS simulator writes the ISO gain map without its metadata, which ImageIO
  /// then refuses to add to a photo. Devices write the metadata.
  private func skipUnlessCoreImageWritesGainMapMetadata() throws {
    guard #available(iOS 18.0, *) else { return }
    let sdr = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(
      to: CGRect(x: 0, y: 0, width: 8, height: 8))
    let hdr = CIImage(cvPixelBuffer: makeHLGFrame(8, 8))
    guard
      let data = CIContext().jpegRepresentation(
        of: sdr, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        options: [.hdrImage: hdr]),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
      info[kCGImageAuxiliaryDataInfoMetadata] != nil
    else {
      throw XCTSkip("Core Image does not write ISO gain map metadata in this environment.")
    }
  }

  func testAddingGainMapKeepsThePhotoAndItsMetadata() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Requires iOS 18.") }
    // A portrait photo keeps landscape sensor pixels; the video frame is already upright.
    let photo = makeJPEG(400, 300, orientation: .right)
    XCTAssertFalse(HDRPhotoGainMap.containsGainMap(photo))
    try skipUnlessCoreImageWritesGainMapMetadata()

    let result = try XCTUnwrap(
      HDRPhotoGainMap.addingGainMap(
        to: photo, hdrFrame: makeHLGFrame(300, 400), context: CIContext()))

    XCTAssertTrue(HDRPhotoGainMap.containsGainMap(result))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
    XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 400)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 300)
    XCTAssertEqual(properties[kCGImagePropertyOrientation] as? UInt32, 6)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    XCTAssertEqual(exif?[kCGImagePropertyExifLensModel] as? String, "test lens")
  }

  func testAddingGainMapShowsTheHLGFrameValuesAsHDR() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Requires iOS 18.") }
    try skipUnlessCoreImageWritesGainMapMetadata()
    let photo = makeJPEG(400, 300, orientation: .up)
    let frame = makeHLGFrame(400, 300)

    let result = try XCTUnwrap(
      HDRPhotoGainMap.addingGainMap(to: photo, hdrFrame: frame, context: CIContext()))

    // The HDR rendition must equal the frame as the HLG preview shows it (BT.2100, BT.2408
    // reference white at 1.0), not a rescaled version of it.
    let expected = luminance(of: CIImage(cvPixelBuffer: frame))
    let hdr = try XCTUnwrap(CIImage(data: result, options: [.expandToHDR: true]))
    XCTAssertGreaterThan(expected, 1, "The test frame must be brighter than SDR white.")
    XCTAssertEqual(luminance(of: hdr), expected, accuracy: expected * 0.02)
  }

  private func luminance(of image: CIImage) -> Float {
    var pixel = [Float](repeating: 0, count: 4)
    let center = CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1)
    CIContext().render(
      image, toBitmap: &pixel, rowBytes: 16, bounds: center, format: .RGBAf,
      colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!)
    return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
  }

  func testAddingGainMapFailsWhenTheFrameHasAnotherAspectRatio() throws {
    guard #available(iOS 18.0, *) else { throw XCTSkip("Requires iOS 18.") }
    let photo = makeJPEG(400, 300, orientation: .up)

    XCTAssertNil(
      HDRPhotoGainMap.addingGainMap(
        to: photo, hdrFrame: makeHLGFrame(320, 180), context: CIContext()))
  }

  func testInverseOrientationUndoesRotations() {
    XCTAssertEqual(HDRPhotoGainMap.inverse(of: .right), .left)
    XCTAssertEqual(HDRPhotoGainMap.inverse(of: .left), .right)
    XCTAssertEqual(HDRPhotoGainMap.inverse(of: .down), .down)
    XCTAssertEqual(HDRPhotoGainMap.inverse(of: .up), .up)
  }

  // MARK: Preview frame

  func testCapturePreviewFrameIsNil_whenThePreviewIsSDR() {
    let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440)])
    let camera = makeCamera(device: device, range: .sdr)

    let done = expectation(description: "frame")
    camera.capturePreviewFrame { data in
      XCTAssertNil(data)
      done.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  func testPreviewJPEGIsScaledToTheShortSide() throws {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1920, 1440, kCVPixelFormatType_32BGRA, nil, &buffer)
    let jpeg = try XCTUnwrap(DefaultCamera.makePreviewJPEG(from: buffer!, shortSide: 360))

    let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 480)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 360)
  }

  // MARK: Video settings

  func testVideoSettingsAreNeverSetToAFormatThatIsNotAvailable() {
    let device = makeDevice(formats: [makeFormat(yuv420, 4032, 3024), makeHLGFormat(1920, 1440)])
    let camera = makeCamera(device: device)
    XCTAssertEqual(camera.previewDynamicRange, .hlg10)

    // With the 10-bit format active, only the 10-bit formats are available.
    let output = MockCaptureVideoDataOutput()
    // 0x2D78_7630 is -xv0 and 0x2678_7630 is &xv0.
    let available: [FourCharCode] = [x420, 0x2D78_7630, 0x2678_7630]
    output.availableVideoPixelFormatTypes = available
    camera.captureVideoOutput = output

    camera.videoFormat = kCVPixelFormatType_32BGRA
    camera.videoFormat = yuv420

    XCTAssertFalse(output.videoSettingsHistory.isEmpty)
    for settings in output.videoSettingsHistory {
      let format = settings?[kCVPixelBufferPixelFormatTypeKey as String] as? FourCharCode
      XCTAssertEqual(format, x420)
    }
    XCTAssertEqual(camera.videoFormat, x420)
  }

  func testVideoSettingsAreNotSet_whenNoUsableFormatIsAvailable() {
    let camera = CameraTestUtils.createTestCamera()
    let output = MockCaptureVideoDataOutput()
    output.availableVideoPixelFormatTypes = [x420]
    camera.captureVideoOutput = output

    camera.videoFormat = kCVPixelFormatType_32BGRA

    XCTAssertTrue(output.videoSettingsHistory.isEmpty)
  }

  func testVideoSettingsUseTheRequestedFormat_whenAvailable() {
    let camera = CameraTestUtils.createTestCamera()
    let output = MockCaptureVideoDataOutput()
    camera.captureVideoOutput = output

    camera.videoFormat = yuv420

    let format =
      output.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? FourCharCode
    XCTAssertEqual(format, yuv420)
    XCTAssertEqual(camera.videoFormat, yuv420)
  }

  func testResolveVideoPixelFormat() {
    XCTAssertEqual(
      FormatUtils.resolveVideoPixelFormat(
        requested: yuv420, available: [yuv420, x420], hlgActive: true), yuv420)
    XCTAssertEqual(
      FormatUtils.resolveVideoPixelFormat(
        requested: yuv420, available: [x420], hlgActive: true), x420)
    XCTAssertNil(
      FormatUtils.resolveVideoPixelFormat(
        requested: yuv420, available: [x420], hlgActive: false))
    XCTAssertNil(
      FormatUtils.resolveVideoPixelFormat(
        requested: yuv420, available: [], hlgActive: true))
  }
}
