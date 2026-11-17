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
private let x422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange

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

private func makePhotoFormat(
  _ codecType: OSType, _ width: Int32, _ height: Int32, photo: [(Int32, Int32)],
  hlg: Bool = false
) -> MockCaptureDeviceFormat {
  let format = makeFormat(
    codecType, width, height, colorSpaces: hlg ? [.sRGB, .HLG_BT2020] : [.sRGB])
  format.supportedMaxPhotoDimensions = photo.map { CMVideoDimensions(width: $0.0, height: $0.1) }
  return format
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

  // MARK: Photo format (Zelly patch)


  /// The back wide camera formats of an iPhone 14 Pro (iOS 27.2.1) that matter for photos.
  private struct IPhone14ProFormats {
    let hlg4x3x422 = makePhotoFormat(x422, 1920, 1440, photo: [(4032, 3024)], hlg: true)
    let hlg4x3 = makePhotoFormat(x420, 1920, 1440, photo: [(4032, 3024)], hlg: true)
    let hlg1080 = makePhotoFormat(x420, 1920, 1080, photo: [(1920, 1080)], hlg: true)
    let hlg4K = makePhotoFormat(x420, 3840, 2160, photo: [(4224, 2376)], hlg: true)
    let hlg4K60 = makePhotoFormat(x420, 3840, 2160, photo: [], hlg: true)
    let sdr4x3 = makePhotoFormat(yuv420, 1920, 1440, photo: [(4032, 3024)])
    let sdr4K = makePhotoFormat(yuv420, 3840, 2160, photo: [(4224, 2376)])
    let sdrFull = makePhotoFormat(yuv420, 4032, 3024, photo: [(4032, 3024), (8064, 6048)])

    var all: [MockCaptureDeviceFormat] {
      [hlg1080, hlg4K, hlg4K60, hlg4x3x422, hlg4x3, sdr4x3, sdr4K, sdrFull]
    }
  }

  private func choose(
    _ formats: [MockCaptureDeviceFormat], _ preset: PlatformResolutionPreset, useHLG: Bool,
    zeroShutterLag: [MockCaptureDeviceFormat] = []
  ) -> (format: CaptureDeviceFormat, photoDimensions: CMVideoDimensions)? {
    return DefaultCamera.choosePhotoFormat(
      among: formats, rule: DefaultCamera.photoFormatRule(for: preset)!, useHLG: useHLG,
      videoDimensions: dimensions(of:),
      supportsZeroShutterLag: { format in zeroShutterLag.contains { $0 === format } })
  }

  func testPhotoFormat_4x3WithHLGChoosesThe4x3HLGFormat() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let formats = IPhone14ProFormats()

    let chosen = choose(formats.all, .high, useHLG: true, zeroShutterLag: [formats.sdrFull])

    XCTAssertTrue(chosen?.format === formats.hlg4x3)
    XCTAssertEqual(chosen?.photoDimensions.width, 4032)
    XCTAssertEqual(chosen?.photoDimensions.height, 3024)
  }

  func testPhotoFormat_16x9WithHLGChoosesThe4KHLGFormatWithAPhotoSize() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let formats = IPhone14ProFormats()

    let chosen = choose(formats.all, .ultraHigh, useHLG: true)

    XCTAssertTrue(chosen?.format === formats.hlg4K)
    XCTAssertEqual(chosen?.photoDimensions.width, 4224)
    XCTAssertEqual(chosen?.photoDimensions.height, 2376)
  }

  func testPhotoFormat_4x3SDRChoosesTheZeroShutterLagFormatWithoutThe48MPMode() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let formats = IPhone14ProFormats()

    let chosen = choose(formats.all, .high, useHLG: false, zeroShutterLag: [formats.sdrFull])

    XCTAssertTrue(chosen?.format === formats.sdrFull)
    XCTAssertEqual(chosen?.photoDimensions.width, 4032)
    XCTAssertEqual(chosen?.photoDimensions.height, 3024)
  }

  func testPhotoFormat_withoutZeroShutterLagPrefersSmallerVideo() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let formats = IPhone14ProFormats()

    let chosen = choose(formats.all, .high, useHLG: false)

    XCTAssertTrue(chosen?.format === formats.sdr4x3)
  }

  func testPhotoFormat_16x9SDRKeeps4KVideo() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let formats = IPhone14ProFormats()

    let chosen = choose(formats.all, .ultraHigh, useHLG: false, zeroShutterLag: [formats.sdrFull])

    XCTAssertTrue(chosen?.format === formats.sdr4K)
  }

  func testPhotoPresetWithHLGAppliesTheHLGFormat() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let sdr = makePhotoFormat(yuv420, 1920, 1440, photo: [(4032, 3024)])
    let hlg = makePhotoFormat(x420, 1920, 1440, photo: [(4032, 3024)], hlg: true)
    let device = makeDevice(formats: [sdr, hlg])

    let camera = makeCamera(device: device, preset: .high, range: .hlg10)

    XCTAssertTrue(activeFormat === hlg)
    XCTAssertEqual(camera.previewDynamicRange, .hlg10)
    XCTAssertEqual(device.activeColorSpace, .HLG_BT2020)
  }

  func testPhotoPresetWithHLGStaysSDRWithoutAnHLGFormat() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let sdr = makePhotoFormat(yuv420, 1920, 1440, photo: [(4032, 3024)])
    let device = makeDevice(formats: [sdr])

    let camera = makeCamera(device: device, preset: .high, range: .hlg10)

    XCTAssertTrue(activeFormat === sdr)
    XCTAssertEqual(camera.previewDynamicRange, .sdr)
  }

  func testVideoPresetKeepsThePresetFormatChoice() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Requires iOS 16.") }
    let fourByThree = makePhotoFormat(yuv420, 1920, 1440, photo: [(4032, 3024)])
    let device = makeDevice(formats: [fourByThree])
    let session = MockCaptureSession()

    _ = makeCamera(device: device, preset: .veryHigh, range: .sdr, session: session)

    XCTAssertEqual(session.sessionPreset, .hd1920x1080)
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
