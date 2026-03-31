import AVFoundation
import Foundation
import Photos

enum CaptureMode: String, CaseIterable, Codable, Identifiable {
    case manualPhoto
    case constantColor

    var id: Self { self }

    var title: String {
        switch self {
        case .manualPhoto:
            return "Manual Photo"
        case .constantColor:
            return "Constant Color"
        }
    }

    var shortTitle: String {
        switch self {
        case .manualPhoto:
            return "MANUAL"
        case .constantColor:
            return "CONSTANT"
        }
    }

    var subtitle: String {
        switch self {
        case .manualPhoto:
            return "Processed HEIC or JPEG with pro controls"
        case .constantColor:
            return "Repeatable color with flash on supported devices"
        }
    }

    var captureMessage: String {
        switch self {
        case .manualPhoto:
            return "Capturing Manual Photo…"
        case .constantColor:
            return "Capturing Constant Color photo…"
        }
    }
}

enum RearLens: String, CaseIterable, Codable, Identifiable {
    case ultraWide
    case wide
    case telephoto

    var id: Self { self }

    init?(deviceType: AVCaptureDevice.DeviceType) {
        switch deviceType {
        case .builtInUltraWideCamera:
            self = .ultraWide
        case .builtInWideAngleCamera:
            self = .wide
        case .builtInTelephotoCamera:
            self = .telephoto
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .ultraWide:
            return "Ultra"
        case .wide:
            return "Wide"
        case .telephoto:
            return "Tele"
        }
    }

    var detail: String {
        switch self {
        case .ultraWide:
            return "Widest rear lens"
        case .wide:
            return "Primary rear lens"
        case .telephoto:
            return "Tight rear framing"
        }
    }

    var systemImage: String {
        switch self {
        case .ultraWide:
            return "arrow.left.and.right.circle"
        case .wide:
            return "viewfinder.circle"
        case .telephoto:
            return "plus.magnifyingglass"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide:
            return .builtInUltraWideCamera
        case .wide:
            return .builtInWideAngleCamera
        case .telephoto:
            return .builtInTelephotoCamera
        }
    }

    static func resolvedPreferred(_ preferred: RearLens, available: [RearLens]) -> RearLens {
        if available.contains(preferred) {
            return preferred
        }

        if available.contains(.wide) {
            return .wide
        }

        return available.first ?? .wide
    }
}

enum CaptureSaveFormat: String, CaseIterable, Codable, Equatable, Identifiable {
    case heic = "HEIC"
    case jpeg = "JPEG"

    var id: Self { self }

    var fileExtension: String {
        switch self {
        case .heic:
            return "heic"
        case .jpeg:
            return "jpg"
        }
    }

    var fileType: AVFileType {
        switch self {
        case .heic:
            return .heic
        case .jpeg:
            return .jpg
        }
    }

    var codec: AVVideoCodecType {
        switch self {
        case .heic:
            return .hevc
        case .jpeg:
            return .jpeg
        }
    }

    var uniformTypeIdentifier: String {
        fileType.rawValue
    }

    var detail: String {
        switch self {
        case .heic:
            return "Smaller files"
        case .jpeg:
            return "Broader compatibility"
        }
    }
}

enum CaptureDriveMode: String, CaseIterable, Codable, Equatable, Identifiable {
    case single
    case bracket
    case longExposure

    var id: Self { self }

    var title: String {
        switch self {
        case .single:
            return "Single"
        case .bracket:
            return "Bracket"
        case .longExposure:
            return "Long"
        }
    }

    var detail: String {
        switch self {
        case .single:
            return "Save one photo per press."
        case .bracket:
            return "Capture a three-shot exposure bracket."
        case .longExposure:
            return "Use a slower still shutter with a short stability delay."
        }
    }
}

enum LongExposureMode: String, CaseIterable, Codable, Equatable, Identifiable {
    case manual
    case nightAuto

    var id: Self { self }

    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .nightAuto:
            return "Night Auto"
        }
    }

    var detail: String {
        switch self {
        case .manual:
            return "Uses the shutter time you pick."
        case .nightAuto:
            return "Meters the scene and chooses a darker-scene long exposure recipe automatically."
        }
    }
}

enum NightAutoPreset: String, CaseIterable, Codable, Equatable, Identifiable {
    case handheld
    case tripod

    var id: Self { self }

    var title: String {
        switch self {
        case .handheld:
            return "Handheld"
        case .tripod:
            return "Tripod"
        }
    }

    var detail: String {
        switch self {
        case .handheld:
            return "Keeps shutters shorter so Night Auto is easier to hand hold."
        case .tripod:
            return "Leans into longer shutters and more stacking when the phone is supported."
        }
    }
}

enum PermissionState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    init(cameraStatus: AVAuthorizationStatus) {
        switch cameraStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .denied
        }
    }

    init(photoStatus: PHAuthorizationStatus) {
        switch photoStatus {
        case .notDetermined:
            self = .notDetermined
        case .authorized, .limited:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .denied
        }
    }

    var isAuthorized: Bool {
        self == .authorized
    }

    var needsSettingsChange: Bool {
        self == .denied || self == .restricted
    }

    var label: String {
        switch self {
        case .notDetermined:
            return "Pending"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        }
    }
}

enum ExposureControlMode: String, Codable, CaseIterable, Identifiable {
    case auto = "fullAuto"
    case ap = "auto"
    case av
    case tv
    case manual

    var id: Self { self }

    var title: String {
        switch self {
        case .auto:
            return "Auto"
        case .ap:
            return "AP"
        case .av:
            return "AV"
        case .tv:
            return "TV"
        case .manual:
            return "M"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .auto:
            return "Full Auto"
        case .ap:
            return "Auto Program"
        case .av:
            return "AV"
        case .tv:
            return "TV"
        case .manual:
            return "Manual"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "Full automatic exposure."
        case .ap:
            return "Program auto with exposure compensation."
        case .av:
            return "ISO priority on iPhone, since aperture is fixed."
        case .tv:
            return "Shutter priority with automatic ISO."
        case .manual:
            return "Full manual shutter and ISO."
        }
    }

    var usesExposureBias: Bool {
        self == .ap
    }

    var usesManualShutter: Bool {
        self == .tv || self == .manual
    }

    var usesManualISO: Bool {
        self == .av || self == .manual
    }

    var requiresManualExposureSupport: Bool {
        self == .av || self == .tv || self == .manual
    }

    var usesAutomaticExposureLoop: Bool {
        self == .auto || self == .ap
    }
}

enum FocusControlMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case manual

    var id: Self { self }
}

enum WhiteBalanceControlMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case manual

    var id: Self { self }
}

struct ManualControlState: Codable, Equatable {
    static let defaultShutterSeconds = 1.0 / 120.0
    static let defaultISO = 100.0
    static let defaultWhiteBalanceTemperature = 5_200.0

    var exposureMode: ExposureControlMode = .auto
    var exposureBias: Double = 0
    var manualShutterSeconds: Double = defaultShutterSeconds
    var manualISO: Double = defaultISO
    var focusMode: FocusControlMode = .auto
    var lensPosition: Double = 1.0
    var whiteBalanceMode: WhiteBalanceControlMode = .auto
    var whiteBalanceTemperature: Double = defaultWhiteBalanceTemperature
}

struct PreviewAssistState: Codable, Equatable {
    var showGrid = true
    var showHistogram = false
    var showHighlightWarning = false
    var showFocusPeaking = false
    var showLevel = false
}

struct HistogramSnapshot: Equatable {
    let bins: [Double]
    let clippedRatio: Double

    static let empty = HistogramSnapshot(
        bins: Array(repeating: 0, count: 24),
        clippedRatio: 0
    )

    var hasSignal: Bool {
        bins.contains(where: { $0 > 0 })
    }
}

struct CaptureCapabilities: Equatable {
    var availableSaveFormats: [CaptureSaveFormat]
    var availableLenses: [RearLens]
    var selectedLens: RearLens
    var supportsHeic: Bool
    var supportsConstantColor: Bool
    var supportsManualExposure: Bool
    var supportsManualFocus: Bool
    var supportsPointOfInterest: Bool
    var supportsWhiteBalanceLock: Bool
    var supportsLowLightBoost: Bool
    var maxBracketedCaptureCount: Int
    var minExposureBias: Double
    var maxExposureBias: Double
    var minISO: Double
    var maxISO: Double
    var minShutterSeconds: Double
    var maxShutterSeconds: Double
    var lensAperture: Double
    var deviceName: String
    var constantColorUnavailableReason: String?

    static var defaultDeviceName: String {
#if targetEnvironment(simulator)
        "iOS Simulator"
#else
        "Rear Camera"
#endif
    }

    static let initial = CaptureCapabilities(
        availableSaveFormats: [.heic, .jpeg],
        availableLenses: [.wide],
        selectedLens: .wide,
        supportsHeic: false,
        supportsConstantColor: false,
        supportsManualExposure: false,
        supportsManualFocus: false,
        supportsPointOfInterest: false,
        supportsWhiteBalanceLock: false,
        supportsLowLightBoost: false,
        maxBracketedCaptureCount: 1,
        minExposureBias: -2,
        maxExposureBias: 2,
        minISO: 25,
        maxISO: 800,
        minShutterSeconds: 1.0 / 2_000.0,
        maxShutterSeconds: 1.0,
        lensAperture: 1.6,
        deviceName: defaultDeviceName,
        constantColorUnavailableReason: "Constant Color isn't available on the current device or selected rear lens."
    )

    var exposureBiasRange: ClosedRange<Double> {
        minExposureBias...maxExposureBias
    }

    var isoRange: ClosedRange<Double> {
        minISO...maxISO
    }

    var shutterRange: ClosedRange<Double> {
        minShutterSeconds...maxShutterSeconds
    }
}

struct CaptureResult: Equatable {
    let mode: CaptureMode
    let fileFormat: CaptureSaveFormat
    let localIdentifier: String
    let savedAssetCount: Int
    let summaryMessage: String?

    var message: String {
        if let summaryMessage {
            return summaryMessage
        }

        switch mode {
        case .manualPhoto:
            return savedAssetCount == 1
                ? "Saved a single \(fileFormat.rawValue) photo to Photos."
                : "Saved \(savedAssetCount) \(fileFormat.rawValue) photos to Photos."
        case .constantColor:
            return "Saved a single Constant Color \(fileFormat.rawValue) photo to Photos."
        }
    }
}

struct StatusBanner: Equatable {
    enum Kind: Equatable {
        case info
        case success
        case error
    }

    let kind: Kind
    let message: String
}
