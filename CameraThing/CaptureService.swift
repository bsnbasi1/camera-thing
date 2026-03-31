import AVFoundation
import Combine
import CoreImage
import CoreMotion
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit

final class CaptureService: NSObject, ObservableObject {
    @Published private(set) var cameraPermission: PermissionState = .notDetermined
    @Published private(set) var photoPermission: PermissionState = .notDetermined
    @Published private(set) var capabilities: CaptureCapabilities = .initial
    @Published private(set) var isSessionConfigured = false
    @Published private(set) var isSessionRunning = false
    @Published private(set) var isCaptureInProgress = false
    @Published private(set) var statusBanner: StatusBanner?
    @Published private(set) var lastResult: CaptureResult?
    @Published private(set) var selectedMode: CaptureMode
    @Published private(set) var selectedDriveMode: CaptureDriveMode
    @Published private(set) var selectedLens: RearLens
    @Published private(set) var selectedSaveFormat: CaptureSaveFormat
    @Published private(set) var manualState: ManualControlState
    @Published private(set) var previewAssistState: PreviewAssistState
    @Published private(set) var isFocusExposureLocked = false
    @Published private(set) var histogramSnapshot: HistogramSnapshot = .empty
    @Published private(set) var highlightWarningOverlay: UIImage?
    @Published private(set) var focusPeakingOverlay: UIImage?
    @Published private(set) var liveExposureShutterSeconds = ManualControlState.defaultShutterSeconds
    @Published private(set) var liveExposureISO = ManualControlState.defaultISO
    @Published private(set) var selectedLongExposureSeconds = 1.0
    @Published private(set) var selectedLongExposureMode: LongExposureMode
    @Published private(set) var selectedNightAutoPreset: NightAutoPreset
    @Published private(set) var levelAngleDegrees = 0.0

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "camera-thing.session", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "camera-thing.analysis", qos: .userInitiated)
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "camera-thing.motion"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let motionManager = CMMotionManager()
    private let preferencesStore: UserDefaults
    private let ciContext = CIContext()
    private var videoInput: AVCaptureDeviceInput?
    private var cameraDevice: AVCaptureDevice?
    private var videoRotationAngle: CGFloat = 90
    private var didRequestInitialPermissions = false
    private var hasConfiguredSession = false
    private var isConfiguringSession = false
    private var activeProcessor: NSObject?
    private var lastPreviewAnalysisTimestamp = 0.0

    init(preferencesStore: UserDefaults = .standard) {
        self.preferencesStore = preferencesStore
        let storedPreferences = Self.loadPreferences(from: preferencesStore) ?? StoredPreferences()
        self.selectedMode = .manualPhoto
        self.selectedDriveMode = storedPreferences.selectedDriveMode
        self.selectedLens = storedPreferences.selectedLens
        self.selectedSaveFormat = storedPreferences.selectedSaveFormat
        self.manualState = storedPreferences.manualState
        self.previewAssistState = storedPreferences.previewAssistState
        self.selectedLongExposureSeconds = storedPreferences.selectedLongExposureSeconds
        self.selectedLongExposureMode = storedPreferences.selectedLongExposureMode
        self.selectedNightAutoPreset = storedPreferences.selectedNightAutoPreset
        super.init()
    }

    var canCapture: Bool {
        cameraPermission.isAuthorized &&
        photoPermission.isAuthorized &&
        isSessionConfigured &&
        isSessionRunning &&
        !isCaptureInProgress &&
        isSelectedModeSupported &&
        isSelectedDriveModeSupported
    }

    var environmentNotice: String? {
        guard isRunningInSimulator else { return nil }
        return "The iOS Simulator can verify layout and permission flow, but live preview, manual capture behavior, and Constant Color need a real iPhone."
    }

    var modeNotice: String? {
        if selectedMode == .constantColor {
            if !capabilities.supportsConstantColor {
                return capabilities.constantColorUnavailableReason
            }

            return "Constant Color uses flash and may take a few seconds per shot while it builds a repeatable color render."
        }

        return nil
    }

    var driveModeNotice: String? {
        switch selectedDriveMode {
        case .single:
            return nil
        case .bracket:
            guard supportsBracketCapture else {
                return "Exposure bracketing isn't available on the current camera configuration."
            }
            return "Bracket captures three processed photos at different exposures so you can keep the one you like best."
        case .longExposure:
            guard supportsLongExposure else {
                return "Long Exposure needs manual shutter control on the current rear lens."
            }
            switch selectedLongExposureMode {
            case .manual:
                return "Long Exposure uses a slower still shutter after a short delay. It works best on a tripod or a very steady surface."
            case .nightAuto:
                let plan = resolvedNightAutoExposurePlan()
                let boostNote = capabilities.supportsLowLightBoost ? " It can also use low-light boost while framing." : ""
                return "Night Auto \(selectedNightAutoPreset.title.lowercased()) meters a stacked low-light exposure around \(nightAutoPlanSummary(plan)).\(boostNote)"
            }
        }
    }

    var permissionGuidance: String? {
        if cameraPermission.needsSettingsChange && photoPermission.needsSettingsChange {
            return "Enable Camera and Photo Library Add Only access in Settings to preview and save photos."
        }

        if cameraPermission.needsSettingsChange {
            return "Enable Camera access in Settings to use the rear main camera preview."
        }

        if photoPermission.needsSettingsChange {
            return "Enable Photo Library Add Only access in Settings to save each capture directly to Photos."
        }

        return nil
    }

    var shouldShowSettingsButton: Bool {
        cameraPermission.needsSettingsChange || photoPermission.needsSettingsChange
    }

    var captureHint: String {
        if isCaptureInProgress {
            return "Finishing the current capture and save…"
        }

        if !cameraPermission.isAuthorized {
            return "Camera access is required to show the rear main preview."
        }

        if !photoPermission.isAuthorized {
            return "Photo Library Add Only access is required to save each shot."
        }

        if let environmentNotice {
            return environmentNotice
        }

        if selectedMode == .constantColor && !capabilities.supportsConstantColor {
            return capabilities.constantColorUnavailableReason ?? "Constant Color isn't available on the current device or rear main camera format."
        }

        if selectedDriveMode == .bracket && !supportsBracketCapture {
            return "Exposure bracketing isn't available on the current camera configuration."
        }

        if selectedDriveMode == .longExposure && !supportsLongExposure {
            return "Long Exposure needs manual shutter support on the current rear lens."
        }

        if !isSessionConfigured {
            return "Configuring the rear main camera and pro controls…"
        }

        if !isSessionRunning {
            return "The preview restarts when the app becomes active."
        }

        switch selectedMode {
        case .manualPhoto:
            switch selectedDriveMode {
            case .single:
                return "Manual Photo saves one processed \(selectedSaveFormat.rawValue) photo when available."
            case .bracket:
                return "Bracket saves three processed \(selectedSaveFormat.rawValue) photos with different exposures."
            case .longExposure:
                switch selectedLongExposureMode {
                case .manual:
                    return "Long Exposure uses \(longExposureReadout) with a short delay before capture. Best on a tripod."
                case .nightAuto:
                    return "Night Auto \(selectedNightAutoPreset.title.lowercased()) meters the scene for a stacked low-light shot around \(nightAutoPlanReadout)."
                }
            }
        case .constantColor:
            return "Constant Color saves one \(selectedSaveFormat.rawValue) photo, uses flash, and may take a little longer to capture."
        }
    }

    var shutterReadout: String {
        switch manualState.exposureMode {
        case .manual, .tv:
            return formatShutter(manualState.manualShutterSeconds)
        case .av, .ap, .auto:
            return formatShutter(liveExposureShutterSeconds.clamped(to: capabilities.shutterRange))
        }
    }

    var isoReadout: String {
        switch manualState.exposureMode {
        case .manual, .av:
            return "ISO \(Int(manualState.manualISO.rounded()))"
        case .tv, .ap, .auto:
            return "ISO \(Int(liveExposureISO.rounded()))"
        }
    }

    var focusReadout: String {
        if manualState.focusMode == .manual {
            return "MF \(Int((manualState.lensPosition * 100).rounded()))%"
        }

        return isFocusExposureLocked ? "AE/AF LOCK" : "AUTO"
    }

    var whiteBalanceReadout: String {
        effectiveWhiteBalanceMode == .manual
            ? "\(Int(manualState.whiteBalanceTemperature.rounded()))K"
            : "AUTO"
    }

    var apertureReadout: String {
        String(format: "f/%.1f", capabilities.lensAperture)
    }

    var longExposureReadout: String {
        formatShutter(selectedLongExposureSeconds.clamped(to: capabilities.shutterRange))
    }

    var longExposureModeReadout: String {
        switch selectedLongExposureMode {
        case .manual:
            return longExposureReadout
        case .nightAuto:
            return nightAutoPlanReadout
        }
    }

    var nightAutoPlanReadout: String {
        nightAutoPlanSummary(resolvedNightAutoExposurePlan())
    }

    var supportsBracketCapture: Bool {
        selectedMode == .manualPhoto && capabilities.maxBracketedCaptureCount >= 3
    }

    var supportsLongExposure: Bool {
        selectedMode == .manualPhoto && capabilities.supportsManualExposure && capabilities.maxBracketedCaptureCount >= 2
    }

    var longExposureChoices: [Double] {
        let maxShutter = capabilities.maxShutterSeconds
        let minShutter = min(max(capabilities.minShutterSeconds, 0.25), maxShutter)
        let candidates = [0.5, 1.0, 2.0, 4.0, maxShutter]
            .map { $0.clamped(to: minShutter...maxShutter) }
            .filter { $0 >= minShutter && $0 <= maxShutter }
            .sorted()

        var unique: [Double] = []
        for candidate in candidates {
            if unique.contains(where: { abs($0 - candidate) < 0.05 }) {
                continue
            }
            unique.append(candidate)
        }

        return unique.isEmpty ? [maxShutter] : unique
    }

    var exposureControlNote: String? {
        switch manualState.exposureMode {
        case .auto:
            return "Full auto lets the iPhone meter shutter and ISO for you."
        case .ap:
            return "AP works like program auto with exposure compensation."
        case .av:
            return capabilities.supportsManualExposure
                ? "On iPhone the aperture is fixed, so AV acts like ISO priority while shutter is metered automatically."
                : "AV isn't available on the current camera configuration."
        case .tv:
            return capabilities.supportsManualExposure
                ? "TV keeps shutter fixed and meters ISO automatically."
                : "TV isn't available on the current camera configuration."
        case .manual:
            return capabilities.supportsManualExposure
                ? nil
                : "Manual shutter and ISO aren't available on the current camera configuration."
        }
    }

    var focusControlNote: String? {
        if !capabilities.supportsPointOfInterest && !capabilities.supportsManualFocus {
            return "Tap-to-meter and manual focus aren't available on the current camera configuration."
        }

        if !capabilities.supportsManualFocus {
            return capabilities.supportsPointOfInterest
                ? "Tap the preview to meter. Hold to lock AE/AF."
                : "Manual focus isn't available on the current camera configuration."
        }

        return capabilities.supportsPointOfInterest
            ? "Tap the preview to meter. Hold to lock AE/AF."
            : nil
    }

    var whiteBalanceControlNote: String? {
        if selectedMode == .constantColor {
            return "Constant Color uses auto white balance for each shot."
        }

        guard !capabilities.supportsWhiteBalanceLock else { return nil }
        return "Manual white balance isn't available on the current camera configuration."
    }

    var driveControlNote: String? {
        if selectedMode == .constantColor {
            return "Constant Color only supports single-photo capture."
        }

        switch selectedDriveMode {
        case .single:
            return "Single capture keeps the workflow simple and fastest."
        case .bracket:
            return supportsBracketCapture
                ? "Bracket captures three exposures around the metered shot."
                : "Exposure bracketing isn't available on the current camera configuration."
        case .longExposure:
            guard supportsLongExposure else {
                return "Long Exposure needs manual shutter support on the current rear lens."
            }
            switch selectedLongExposureMode {
            case .manual:
                return "Manual Long Exposure uses the shutter time you choose with a short anti-shake delay."
            case .nightAuto:
                return selectedNightAutoPreset == .handheld
                    ? "Night Auto Handheld keeps shutters shorter and stacks a lighter low-light recipe."
                    : "Night Auto Tripod leans into longer shutters and more stacking for darker scenes."
            }
        }
    }

    func prepare() {
        refreshPermissionStates()
        refreshMotionUpdatesIfNeeded()

        if cameraPermission.isAuthorized {
            configureSessionIfNeeded()
            startSession()
        }

        if !didRequestInitialPermissions {
            didRequestInitialPermissions = true
            requestOutstandingPermissions()
        } else if photoPermission == .notDetermined {
            requestPhotoPermissionIfNeeded()
        }

        refreshPermissionBannerIfNeeded()
    }

    func pause() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.publishOnMain {
                self.isSessionRunning = false
                self.histogramSnapshot = .empty
                self.highlightWarningOverlay = nil
                self.focusPeakingOverlay = nil
            }
        }

        stopMotionUpdates()
    }

    func selectMode(_ mode: CaptureMode) {
        guard mode != .constantColor || capabilities.supportsConstantColor else {
            publishOnMain {
                self.selectedMode = .manualPhoto
                self.persistPreferences()
                self.statusBanner = StatusBanner(
                    kind: .info,
                    message: self.capabilities.constantColorUnavailableReason ?? "Constant Color isn't available on the current device or rear main camera format."
                )
            }
            return
        }

        guard mode != selectedMode else { return }

        publishOnMain {
            self.selectedMode = mode
            if mode == .constantColor, self.selectedDriveMode != .single {
                self.selectedDriveMode = .single
            }
            self.persistPreferences()
        }

        sessionQueue.async { [weak self] in
            self?.updateModeConfigurationOnQueue()
            self?.applyManualStateOnQueue(announceWhiteBalanceOverride: true)
        }
    }

    func selectDriveMode(_ mode: CaptureDriveMode) {
        if mode == .bracket && !supportsBracketCapture {
            statusBanner = StatusBanner(
                kind: .info,
                message: "Bracket capture isn't available on the current camera configuration."
            )
            return
        }

        if mode == .longExposure && !supportsLongExposure {
            statusBanner = StatusBanner(
                kind: .info,
                message: "Long Exposure needs manual shutter support on the current rear lens."
            )
            return
        }

        guard mode != selectedDriveMode else { return }

        selectedDriveMode = mode
        persistPreferences()
        statusBanner = StatusBanner(kind: .info, message: mode.detail)
    }

    func selectLens(_ lens: RearLens) {
        guard capabilities.availableLenses.contains(lens) else {
            statusBanner = StatusBanner(
                kind: .info,
                message: "\(lens.title) isn't available on this iPhone."
            )
            return
        }

        guard lens != selectedLens else { return }

        sessionQueue.async { [weak self] in
            self?.switchToLensOnQueue(lens)
        }
    }

    func selectSaveFormat(_ format: CaptureSaveFormat) {
        guard capabilities.availableSaveFormats.contains(format) else {
            statusBanner = StatusBanner(
                kind: .info,
                message: "\(format.rawValue) capture isn't available on the current camera configuration."
            )
            return
        }

        guard format != selectedSaveFormat else { return }

        selectedSaveFormat = format
        persistPreferences()
        statusBanner = StatusBanner(
            kind: .info,
            message: "Captured photos will prefer \(format.rawValue)."
        )
    }

    func setGridEnabled(_ isEnabled: Bool) {
        updatePreviewAssistState { state in
            state.showGrid = isEnabled
        }
    }

    func setHistogramEnabled(_ isEnabled: Bool) {
        updatePreviewAssistState { state in
            state.showHistogram = isEnabled
        }
    }

    func setHighlightWarningEnabled(_ isEnabled: Bool) {
        updatePreviewAssistState { state in
            state.showHighlightWarning = isEnabled
        }
    }

    func setFocusPeakingEnabled(_ isEnabled: Bool) {
        updatePreviewAssistState { state in
            state.showFocusPeaking = isEnabled
        }
    }

    func setLevelEnabled(_ isEnabled: Bool) {
        updatePreviewAssistState { state in
            state.showLevel = isEnabled
        }
    }

    func setLongExposureSeconds(_ seconds: Double) {
        selectedLongExposureSeconds = seconds.clamped(to: capabilities.shutterRange)
        persistPreferences()
    }

    func setLongExposureMode(_ mode: LongExposureMode) {
        guard mode != selectedLongExposureMode else { return }
        selectedLongExposureMode = mode
        persistPreferences()
        statusBanner = StatusBanner(kind: .info, message: mode.detail)
        sessionQueue.async { [weak self] in
            self?.applyManualStateOnQueue()
        }
    }

    func setNightAutoPreset(_ preset: NightAutoPreset) {
        guard preset != selectedNightAutoPreset else { return }
        selectedNightAutoPreset = preset
        persistPreferences()
        statusBanner = StatusBanner(kind: .info, message: preset.detail)
        sessionQueue.async { [weak self] in
            self?.applyManualStateOnQueue()
        }
    }

    func setExposureMode(_ mode: ExposureControlMode) {
        if mode.requiresManualExposureSupport && !capabilities.supportsManualExposure {
            statusBanner = StatusBanner(
                kind: .info,
                message: "\(mode.accessibilityTitle) isn't available on the current camera configuration."
            )
            return
        }

        updateManualState(clearLock: true) { state in
            state.exposureMode = mode
        }

        statusBanner = StatusBanner(
            kind: .info,
            message: mode.detail
        )
    }

    func setExposureBias(_ value: Double) {
        updateManualState(clearLock: true) { state in
            state.exposureBias = value
        }
    }

    func setManualShutterSeconds(_ seconds: Double) {
        updateManualState(clearLock: true) { state in
            state.manualShutterSeconds = seconds
        }
    }

    func setManualISO(_ iso: Double) {
        updateManualState(clearLock: true) { state in
            state.manualISO = iso
        }
    }

    func setFocusMode(_ mode: FocusControlMode) {
        if mode == .manual && !capabilities.supportsManualFocus {
            statusBanner = StatusBanner(
                kind: .info,
                message: "Manual focus isn't available on the current camera configuration."
            )
            return
        }

        updateManualState(clearLock: true) { state in
            state.focusMode = mode
        }
    }

    func setLensPosition(_ position: Double) {
        updateManualState(clearLock: true) { state in
            state.lensPosition = position
        }
    }

    func setWhiteBalanceMode(_ mode: WhiteBalanceControlMode) {
        if mode == .manual && !capabilities.supportsWhiteBalanceLock {
            statusBanner = StatusBanner(
                kind: .info,
                message: "Manual white balance isn't available on the current camera configuration."
            )
            return
        }

        updateManualState { state in
            state.whiteBalanceMode = mode
        }
    }

    func setWhiteBalanceTemperature(_ temperature: Double) {
        updateManualState { state in
            state.whiteBalanceTemperature = temperature
        }
    }

    func handlePreviewTap(at point: CGPoint) {
        guard capabilities.supportsPointOfInterest else { return }

        sessionQueue.async { [weak self] in
            self?.handlePreviewPointOnQueue(point, lockExposureAndFocus: false)
        }
    }

    func handlePreviewLongPress(at point: CGPoint) {
        guard capabilities.supportsPointOfInterest || manualState.focusMode == .auto || manualState.exposureMode.usesAutomaticExposureLoop else {
            return
        }

        sessionQueue.async { [weak self] in
            self?.handlePreviewPointOnQueue(point, lockExposureAndFocus: true)
        }
    }

    func capturePhoto() {
        guard canCapture else {
            statusBanner = StatusBanner(kind: .error, message: captureHint)
            return
        }

        let mode = selectedMode
        guard mode != .constantColor || capabilities.supportsConstantColor else {
            statusBanner = StatusBanner(
                kind: .error,
                message: capabilities.constantColorUnavailableReason ?? "Constant Color isn't available on the current device or rear main camera format."
            )
            return
        }

        isCaptureInProgress = true
        lastResult = nil
        let captureMessage: String
        switch selectedDriveMode {
        case .single:
            captureMessage = mode.captureMessage
        case .bracket:
            captureMessage = "Capturing three-shot bracket…"
        case .longExposure:
            switch selectedLongExposureMode {
            case .manual:
                captureMessage = "Preparing long exposure at \(longExposureReadout)…"
            case .nightAuto:
                captureMessage = "Preparing Night Auto \(selectedNightAutoPreset.title.lowercased()) around \(nightAutoPlanReadout)…"
            }
        }
        statusBanner = StatusBanner(kind: .info, message: captureMessage)

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                switch self.selectedDriveMode {
                case .single:
                    let request = try self.makeCaptureRequest(for: mode)
                    let processor = PhotoCaptureProcessor(
                        mode: request.mode,
                        saveFormat: request.saveFormat,
                        onWillSave: { [weak self] format in
                            self?.publishOnMain {
                                self?.statusBanner = StatusBanner(
                                    kind: .info,
                                    message: "Saving \(format.rawValue) to Photos…"
                                )
                            }
                        },
                        onComplete: { [weak self] result in
                            self?.handleCaptureCompletion(result)
                        }
                    )

                    self.activeProcessor = processor
                    self.photoOutput.capturePhoto(with: request.settings, delegate: processor)

                case .bracket:
                    let request = try self.makeBracketCaptureRequest()
                    let processor = BracketCaptureProcessor(
                        mode: request.mode,
                        saveFormat: request.saveFormat,
                        expectedPhotoCount: request.expectedPhotoCount,
                        onWillSave: { [weak self] format in
                            self?.publishOnMain {
                                self?.statusBanner = StatusBanner(
                                    kind: .info,
                                    message: "Saving bracketed \(format.rawValue) photos…"
                                )
                            }
                        },
                        onComplete: { [weak self] result in
                            self?.handleCaptureCompletion(result)
                        }
                    )

                    self.activeProcessor = processor
                    self.photoOutput.capturePhoto(with: request.settings, delegate: processor)

                case .longExposure:
                    let longExposurePlan = self.resolvedLongExposurePlan()
                    let request = try self.makeLongExposureCaptureRequest()
                    let captureLabel = self.selectedLongExposureMode == .nightAuto ? "Night Auto" : "Long Exposure"
                    let filenameSuffix = self.selectedLongExposureMode == .nightAuto ? "NightAuto" : "LongExposure"
                    let processor = LongExposureCaptureProcessor(
                        mode: request.mode,
                        saveFormat: request.saveFormat,
                        expectedPhotoCount: request.expectedPhotoCount,
                        ciContext: self.ciContext,
                        captureLabel: captureLabel,
                        filenameSuffix: filenameSuffix,
                        onWillSave: { [weak self] format in
                            self?.publishOnMain {
                                self?.statusBanner = StatusBanner(
                                    kind: .info,
                                    message: "Rendering \(captureLabel.lowercased()) \(format.rawValue)…"
                                )
                            }
                        },
                        onComplete: { [weak self] result in
                            self?.handleCaptureCompletion(result)
                            self?.sessionQueue.async {
                                self?.applyManualStateOnQueue()
                            }
                        }
                    )

                    self.activeProcessor = processor
                    self.sessionQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(longExposurePlan.stabilityDelayNanoseconds))) { [weak self] in
                        guard let self, self.isCaptureInProgress, self.activeProcessor === processor else { return }
                        self.photoOutput.capturePhoto(with: request.settings, delegate: processor)
                    }
                }
            } catch {
                self.handleCaptureCompletion(.failure(error))
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func setVideoRotationAngle(_ angle: CGFloat) {
        let normalizedAngle = Self.normalizedVideoRotationAngle(angle)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoRotationAngle = normalizedAngle
            self.applyVideoRotationAngleOnQueue()
        }
    }

    private func updateManualState(clearLock: Bool = false, _ update: (inout ManualControlState) -> Void) {
        var nextState = manualState
        update(&nextState)
        nextState = normalizedState(nextState, capabilities: capabilities)
        manualState = nextState

        if clearLock {
            isFocusExposureLocked = false
        }

        persistPreferences()
        sessionQueue.async { [weak self] in
            self?.applyManualStateOnQueue()
        }
    }

    private func updatePreviewAssistState(_ update: (inout PreviewAssistState) -> Void) {
        var nextState = previewAssistState
        update(&nextState)
        previewAssistState = nextState
        persistPreferences()

        if !nextState.showHistogram {
            histogramSnapshot = .empty
        }

        if !nextState.showHighlightWarning {
            highlightWarningOverlay = nil
        }

        if !nextState.showFocusPeaking {
            focusPeakingOverlay = nil
        }

        refreshMotionUpdatesIfNeeded()
    }

    private func requestOutstandingPermissions() {
        if cameraPermission == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                self?.publishOnMain {
                    self?.refreshPermissionStates()
                    self?.refreshPermissionBannerIfNeeded()
                }

                self?.requestPhotoPermissionIfNeeded()

                if granted {
                    self?.configureSessionIfNeeded()
                    self?.startSession()
                }
            }
        } else {
            requestPhotoPermissionIfNeeded()
        }
    }

    private func requestPhotoPermissionIfNeeded() {
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined else {
            publishOnMain {
                self.refreshPermissionStates()
                self.refreshPermissionBannerIfNeeded()
            }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] _ in
            self?.publishOnMain {
                self?.refreshPermissionStates()
                self?.refreshPermissionBannerIfNeeded()
            }
        }
    }

    private func refreshPermissionStates() {
        cameraPermission = PermissionState(cameraStatus: AVCaptureDevice.authorizationStatus(for: .video))
        photoPermission = PermissionState(photoStatus: PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    private func refreshPermissionBannerIfNeeded() {
        guard !isCaptureInProgress else { return }

        if permissionGuidance == nil, lastResult == nil {
            statusBanner = nil
        }
    }

    private func refreshMotionUpdatesIfNeeded() {
        if previewAssistState.showLevel {
            startMotionUpdatesIfNeeded()
        } else {
            stopMotionUpdates()
        }
    }

    private func startMotionUpdatesIfNeeded() {
        guard !isRunningInSimulator else { return }
        guard previewAssistState.showLevel else { return }
        guard motionManager.isDeviceMotionAvailable else { return }
        guard !motionManager.isDeviceMotionActive else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            let angle = atan2(gravity.x, -gravity.y) * 180.0 / .pi
            self.publishOnMain {
                self.levelAngleDegrees = angle
            }
        }
    }

    private func stopMotionUpdates() {
        guard motionManager.isDeviceMotionActive else { return }
        motionManager.stopDeviceMotionUpdates()
    }

    private func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.hasConfiguredSession, !self.isConfiguringSession else { return }

            self.isConfiguringSession = true
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            var shouldStartSession = false
            var configuredCapabilities = CaptureCapabilities.initial
            var configuredMode = self.selectedMode
            var configuredLens = self.selectedLens
            var configuredSaveFormat = self.selectedSaveFormat
            var configuredManualState = self.manualState
            var configurationError: Error?

            do {
                let availableDevices = self.availableRearDevicesByLens()
                let resolvedLens = RearLens.resolvedPreferred(self.selectedLens, available: Array(availableDevices.keys))
                guard let device = availableDevices[resolvedLens] else {
                    throw CaptureServiceError.rearCameraUnavailable
                }

                let input = try AVCaptureDeviceInput(device: device)

                guard self.session.canAddInput(input) else {
                    throw CaptureServiceError.unableToAddInput
                }

                self.session.addInput(input)
                self.videoInput = input

                guard self.session.canAddOutput(self.photoOutput) else {
                    throw CaptureServiceError.unableToAddOutput
                }

                self.session.addOutput(self.photoOutput)

                guard self.session.canAddOutput(self.videoDataOutput) else {
                    throw CaptureServiceError.unableToAddAnalysisOutput
                }

                self.session.addOutput(self.videoDataOutput)
                self.cameraDevice = device
                self.configurePhotoOutput()
                self.configureVideoDataOutput()

                configuredCapabilities = self.detectCapabilities(
                    from: device,
                    availableDevices: availableDevices,
                    selectedLens: resolvedLens
                )
                configuredMode = self.resolveMode(self.selectedMode, capabilities: configuredCapabilities)
                let configuredDriveMode = self.resolveDriveMode(self.selectedDriveMode, mode: configuredMode, capabilities: configuredCapabilities)
                configuredLens = configuredCapabilities.selectedLens
                configuredSaveFormat = self.normalizedSaveFormat(self.selectedSaveFormat, capabilities: configuredCapabilities)
                configuredManualState = self.normalizedState(self.manualState, capabilities: configuredCapabilities)
                let configuredLongExposure = self.normalizedLongExposureSeconds(self.selectedLongExposureSeconds, capabilities: configuredCapabilities)
                self.configureConstantColorPipelineOnQueue(for: configuredMode, capabilities: configuredCapabilities)

                self.hasConfiguredSession = true
                shouldStartSession = true

                self.publishOnMain {
                    self.selectedDriveMode = configuredDriveMode
                    self.selectedLongExposureSeconds = configuredLongExposure
                }
            } catch {
                configurationError = error
                self.hasConfiguredSession = false
                self.cameraDevice = nil
                self.videoInput = nil
            }

            self.session.commitConfiguration()
            self.isConfiguringSession = false

            if let configurationError {
                self.publishOnMain {
                    self.capabilities = CaptureCapabilities.initial
                    self.isSessionConfigured = false
                    self.isSessionRunning = false
                    self.statusBanner = StatusBanner(
                        kind: .error,
                        message: configurationError.localizedDescription
                    )
                }
                return
            }

            self.publishOnMain {
                self.capabilities = configuredCapabilities
                self.selectedMode = configuredMode
                self.selectedLens = configuredLens
                self.selectedSaveFormat = configuredSaveFormat
                self.manualState = configuredManualState
                self.liveExposureShutterSeconds = configuredManualState.manualShutterSeconds
                self.liveExposureISO = configuredManualState.manualISO
                self.selectedDriveMode = self.resolveDriveMode(self.selectedDriveMode, mode: configuredMode, capabilities: configuredCapabilities)
                self.selectedLongExposureSeconds = self.normalizedLongExposureSeconds(self.selectedLongExposureSeconds, capabilities: configuredCapabilities)
                self.isSessionConfigured = true
                self.persistPreferences()
            }

            self.applyManualStateOnQueue()

            if shouldStartSession {
                self.startSessionOnQueue()
            }
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            self?.startSessionOnQueue()
        }
    }

    private func startSessionOnQueue() {
        guard hasConfiguredSession, !session.isRunning else {
            if session.isRunning {
                publishOnMain {
                    self.isSessionRunning = true
                }
            }
            return
        }

        session.startRunning()
        publishOnMain {
            self.isSessionRunning = true
        }
    }

    private func configurePhotoOutput() {
        photoOutput.maxPhotoQualityPrioritization = .speed

        if photoOutput.isLivePhotoCaptureSupported {
            photoOutput.isLivePhotoCaptureEnabled = false
        }

        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = false
        }

        if photoOutput.isPortraitEffectsMatteDeliverySupported {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        }

        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = false
        }

        photoOutput.enabledSemanticSegmentationMatteTypes = []

        if #available(iOS 18.0, *) {
            photoOutput.isConstantColorEnabled = false
        }

        applyVideoRotationAngleOnQueue()
    }

    private func configureVideoDataOutput() {
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: analysisQueue)

        guard let connection = videoDataOutput.connection(with: .video) else {
            return
        }

        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = false
        }

        applyVideoRotationAngleOnQueue()
    }

    private func detectCapabilities(
        from device: AVCaptureDevice,
        availableDevices: [RearLens: AVCaptureDevice],
        selectedLens: RearLens
    ) -> CaptureCapabilities {
        let availableSaveFormats = self.availableSaveFormats()
        let supportsHeic = availableSaveFormats.contains(.heic)

        let minShutterSeconds = max(device.activeFormat.minExposureDuration.seconds, 1.0 / 8_000.0)
        let maxShutterSeconds = max(device.activeFormat.maxExposureDuration.seconds, minShutterSeconds)

        let supportsConstantColor: Bool
        if #available(iOS 18.0, *) {
            supportsConstantColor = photoOutput.isConstantColorSupported
        } else {
            supportsConstantColor = false
        }

        return CaptureCapabilities(
            availableSaveFormats: availableSaveFormats,
            availableLenses: RearLens.allCases.filter { availableDevices[$0] != nil },
            selectedLens: selectedLens,
            supportsHeic: supportsHeic,
            supportsConstantColor: supportsConstantColor,
            supportsManualExposure: device.isExposureModeSupported(.custom),
            supportsManualFocus: device.isLockingFocusWithCustomLensPositionSupported,
            supportsPointOfInterest: device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported,
            supportsWhiteBalanceLock: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            supportsLowLightBoost: device.isLowLightBoostSupported,
            maxBracketedCaptureCount: Int(photoOutput.maxBracketedCapturePhotoCount),
            minExposureBias: Double(device.minExposureTargetBias),
            maxExposureBias: Double(device.maxExposureTargetBias),
            minISO: Double(device.activeFormat.minISO),
            maxISO: Double(device.activeFormat.maxISO),
            minShutterSeconds: minShutterSeconds,
            maxShutterSeconds: maxShutterSeconds,
            lensAperture: Double(device.lensAperture),
            deviceName: device.localizedName,
            constantColorUnavailableReason: supportsConstantColor
                ? nil
                : "Constant Color isn't available on the current device or selected rear lens."
        )
    }

    private func availableRearDevicesByLens() -> [RearLens: AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: RearLens.allCases.map(\.deviceType),
            mediaType: .video,
            position: .back
        )

        var devicesByLens: [RearLens: AVCaptureDevice] = [:]
        for device in discovery.devices {
            guard let lens = RearLens(deviceType: device.deviceType),
                  devicesByLens[lens] == nil else {
                continue
            }

            devicesByLens[lens] = device
        }

        return devicesByLens
    }

    private func switchToLensOnQueue(_ lens: RearLens) {
        guard hasConfiguredSession else { return }

        let availableDevices = availableRearDevicesByLens()
        let resolvedLens = RearLens.resolvedPreferred(lens, available: Array(availableDevices.keys))

        guard let device = availableDevices[resolvedLens] else {
            publishOnMain {
                self.statusBanner = StatusBanner(
                    kind: .error,
                    message: "The selected rear lens isn't available on this iPhone."
                )
            }
            return
        }

        do {
            let nextInput = try AVCaptureDeviceInput(device: device)
            let previousInput = videoInput

            session.beginConfiguration()
            if let previousInput {
                session.removeInput(previousInput)
            }

            guard session.canAddInput(nextInput) else {
                if let previousInput, session.canAddInput(previousInput) {
                    session.addInput(previousInput)
                }
                session.commitConfiguration()
                throw CaptureServiceError.unableToSwitchLens
            }

            session.addInput(nextInput)
            videoInput = nextInput
            cameraDevice = device

            let nextCapabilities = detectCapabilities(
                from: device,
                availableDevices: availableDevices,
                selectedLens: resolvedLens
            )
            let nextMode = resolveMode(selectedMode, capabilities: nextCapabilities)
            let nextDriveMode = resolveDriveMode(selectedDriveMode, mode: nextMode, capabilities: nextCapabilities)
            let nextSaveFormat = normalizedSaveFormat(selectedSaveFormat, capabilities: nextCapabilities)
            let nextManualState = normalizedState(manualState, capabilities: nextCapabilities)
            let nextLongExposure = normalizedLongExposureSeconds(selectedLongExposureSeconds, capabilities: nextCapabilities)

            configureConstantColorPipelineOnQueue(for: nextMode, capabilities: nextCapabilities)
            session.commitConfiguration()

            publishOnMain {
                let previousMode = self.selectedMode
                self.capabilities = nextCapabilities
                self.selectedLens = nextCapabilities.selectedLens
                self.selectedMode = nextMode
                self.selectedDriveMode = nextDriveMode
                self.selectedSaveFormat = nextSaveFormat
                self.manualState = nextManualState
                self.liveExposureShutterSeconds = nextManualState.manualShutterSeconds
                self.liveExposureISO = nextManualState.manualISO
                self.selectedLongExposureSeconds = nextLongExposure
                self.isFocusExposureLocked = false
                self.persistPreferences()

                if previousMode == .constantColor && nextMode == .manualPhoto {
                    self.statusBanner = StatusBanner(
                        kind: .info,
                        message: "Constant Color isn't available on the selected rear lens, so the app returned to Manual Photo."
                    )
                } else {
                    self.statusBanner = StatusBanner(
                        kind: .info,
                        message: "Switched to the \(nextCapabilities.selectedLens.title.lowercased()) rear lens."
                    )
                }
            }

            applyManualStateOnQueue()
        } catch {
            publishOnMain {
                self.statusBanner = StatusBanner(kind: .error, message: error.localizedDescription)
            }
        }
    }

    private func makeCaptureRequest(for mode: CaptureMode) throws -> CaptureRequest {
        let saveFormat = try preferredRenderedFormat()
        let settings = AVCapturePhotoSettings(
            rawPixelFormatType: 0,
            rawFileType: nil,
            processedFormat: [AVVideoCodecKey: saveFormat.codec],
            processedFileType: saveFormat.fileType
        )

        switch mode {
        case .manualPhoto:
            applyProcessedCaptureConfiguration(to: settings, flashMode: .off)
            return CaptureRequest(mode: .manualPhoto, saveFormat: saveFormat, settings: settings, expectedPhotoCount: 1)

        case .constantColor:
            guard capabilities.supportsConstantColor else {
                throw CaptureServiceError.constantColorUnavailable
            }

            guard #available(iOS 18.0, *) else {
                throw CaptureServiceError.constantColorUnavailable
            }

            guard photoOutput.isConstantColorEnabled else {
                throw CaptureServiceError.constantColorUnavailable
            }

            applyProcessedCaptureConfiguration(to: settings, flashMode: .on)
            settings.isConstantColorEnabled = true
            settings.isConstantColorFallbackPhotoDeliveryEnabled = false
            return CaptureRequest(mode: .constantColor, saveFormat: saveFormat, settings: settings, expectedPhotoCount: 1)
        }
    }

    private func makeBracketCaptureRequest() throws -> CaptureRequest {
        guard supportsBracketCapture else {
            throw CaptureServiceError.bracketUnavailable
        }

        let saveFormat = try preferredRenderedFormat()
        let bracketBiases = [-1.0, 0.0, 1.0]
            .map { $0.clamped(to: capabilities.exposureBiasRange) }
        let bracketSettings = bracketBiases.map {
            AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: Float($0))
        }
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            rawFileType: nil,
            processedFormat: [AVVideoCodecKey: saveFormat.codec],
            processedFileType: saveFormat.fileType,
            bracketedSettings: bracketSettings
        )
        applyBracketCaptureConfiguration(to: settings)
        return CaptureRequest(
            mode: .manualPhoto,
            saveFormat: saveFormat,
            settings: settings,
            expectedPhotoCount: bracketSettings.count
        )
    }

    private func makeLongExposureCaptureRequest() throws -> CaptureRequest {
        guard supportsLongExposure else {
            throw CaptureServiceError.longExposureUnavailable
        }

        let saveFormat = try preferredRenderedFormat()
        let longExposurePlan = resolvedLongExposurePlan()
        let shutter = longExposurePlan.shutterSeconds
        let iso = longExposurePlan.iso
        let photoCount = longExposurePlan.photoCount
        let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
        let bracketSettings = (0..<photoCount).map { _ in
            AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration: duration,
                iso: Float(iso)
            )
        }
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            rawFileType: nil,
            processedFormat: [AVVideoCodecKey: saveFormat.codec],
            processedFileType: saveFormat.fileType,
            bracketedSettings: bracketSettings
        )
        applyBracketCaptureConfiguration(to: settings)
        if photoOutput.isLensStabilizationDuringBracketedCaptureSupported {
            settings.isLensStabilizationEnabled = true
        }
        return CaptureRequest(
            mode: .manualPhoto,
            saveFormat: saveFormat,
            settings: settings,
            expectedPhotoCount: bracketSettings.count
        )
    }

    private func availableSaveFormats() -> [CaptureSaveFormat] {
        var formats: [CaptureSaveFormat] = []

        if photoOutput.availablePhotoCodecTypes.contains(.hevc),
           photoOutput.availablePhotoFileTypes.contains(.heic) {
            formats.append(.heic)
        }

        if photoOutput.availablePhotoCodecTypes.contains(.jpeg),
           photoOutput.availablePhotoFileTypes.contains(.jpg) {
            formats.append(.jpeg)
        }

        return formats
    }

    private func normalizedSaveFormat(_ format: CaptureSaveFormat, capabilities: CaptureCapabilities) -> CaptureSaveFormat {
        if capabilities.availableSaveFormats.contains(format) {
            return format
        }

        if capabilities.availableSaveFormats.contains(.heic) {
            return .heic
        }

        if capabilities.availableSaveFormats.contains(.jpeg) {
            return .jpeg
        }

        return format
    }

    private func preferredRenderedFormat() throws -> CaptureSaveFormat {
        let availableFormats = availableSaveFormats()

        if availableFormats.contains(selectedSaveFormat) {
            return selectedSaveFormat
        }

        if availableFormats.contains(.heic) {
            return .heic
        }

        if availableFormats.contains(.jpeg) {
            return .jpeg
        }

        throw CaptureServiceError.renderedCaptureUnavailable
    }

    private func applyProcessedCaptureConfiguration(to settings: AVCapturePhotoSettings, flashMode: AVCaptureDevice.FlashMode) {
        settings.photoQualityPrioritization = .speed
        settings.flashMode = flashMode

        if photoOutput.isAutoRedEyeReductionSupported {
            settings.isAutoRedEyeReductionEnabled = false
        }

        if photoOutput.isVirtualDeviceFusionSupported {
            settings.isAutoVirtualDeviceFusionEnabled = false
        }

        if photoOutput.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = false
            settings.embedsDepthDataInPhoto = false
            settings.isDepthDataFiltered = false
        }

        if photoOutput.isPortraitEffectsMatteDeliverySupported {
            settings.isPortraitEffectsMatteDeliveryEnabled = false
            settings.embedsPortraitEffectsMatteInPhoto = false
        }

        if photoOutput.isContentAwareDistortionCorrectionSupported {
            settings.isAutoContentAwareDistortionCorrectionEnabled = false
        }

        settings.enabledSemanticSegmentationMatteTypes = []
        settings.embedsSemanticSegmentationMattesInPhoto = false
        settings.livePhotoMovieFileURL = nil
    }

    private func applyBracketCaptureConfiguration(to settings: AVCapturePhotoSettings) {
        settings.photoQualityPrioritization = .speed

        if photoOutput.isAutoRedEyeReductionSupported {
            settings.isAutoRedEyeReductionEnabled = false
        }

        if photoOutput.isVirtualDeviceFusionSupported {
            settings.isAutoVirtualDeviceFusionEnabled = false
        }

        if photoOutput.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = false
            settings.embedsDepthDataInPhoto = false
            settings.isDepthDataFiltered = false
        }

        if photoOutput.isPortraitEffectsMatteDeliverySupported {
            settings.isPortraitEffectsMatteDeliveryEnabled = false
            settings.embedsPortraitEffectsMatteInPhoto = false
        }

        if photoOutput.isContentAwareDistortionCorrectionSupported {
            settings.isAutoContentAwareDistortionCorrectionEnabled = false
        }

        settings.enabledSemanticSegmentationMatteTypes = []
        settings.embedsSemanticSegmentationMattesInPhoto = false
    }

    private func updateModeConfigurationOnQueue() {
        guard hasConfiguredSession else { return }

        session.beginConfiguration()
        configureConstantColorPipelineOnQueue(for: selectedMode, capabilities: capabilities)
        session.commitConfiguration()
    }

    private func configureConstantColorPipelineOnQueue(for mode: CaptureMode, capabilities: CaptureCapabilities) {
        guard #available(iOS 18.0, *) else { return }

        let shouldEnable = capabilities.supportsConstantColor && mode == .constantColor
        if photoOutput.isConstantColorEnabled != shouldEnable {
            photoOutput.isConstantColorEnabled = shouldEnable
        }
    }

    private func applyManualStateOnQueue(announceWhiteBalanceOverride: Bool = false) {
        let normalizedState = normalizedState(manualState, capabilities: capabilities)
        let currentMode = selectedMode
        let effectiveWhiteBalanceMode = currentMode == .constantColor ? WhiteBalanceControlMode.auto : normalizedState.whiteBalanceMode
        let exposureMode = normalizedState.exposureMode
        var publishedShutter = normalizedState.manualShutterSeconds
        var publishedISO = normalizedState.manualISO

        withLockedDeviceOnQueue { device in
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable =
                    selectedDriveMode == .longExposure && selectedLongExposureMode == .nightAuto
            }

            let currentShutter = device.exposureDuration.seconds.clamped(to: capabilities.shutterRange)
            let currentISO = Double(device.iso).clamped(to: capabilities.isoRange)

            switch exposureMode {
            case .manual:
                if capabilities.supportsManualExposure {
                    let duration = CMTime(seconds: normalizedState.manualShutterSeconds, preferredTimescale: 1_000_000_000)
                    device.setExposureModeCustom(duration: duration, iso: Float(normalizedState.manualISO), completionHandler: nil)
                    publishedShutter = normalizedState.manualShutterSeconds
                    publishedISO = normalizedState.manualISO
                }
            case .tv:
                if capabilities.supportsManualExposure {
                    let duration = CMTime(seconds: normalizedState.manualShutterSeconds, preferredTimescale: 1_000_000_000)
                    device.setExposureModeCustom(duration: duration, iso: Float(currentISO), completionHandler: nil)
                    publishedShutter = normalizedState.manualShutterSeconds
                    publishedISO = currentISO
                }
            case .av:
                if capabilities.supportsManualExposure {
                    let duration = CMTime(seconds: currentShutter, preferredTimescale: 1_000_000_000)
                    device.setExposureModeCustom(duration: duration, iso: Float(normalizedState.manualISO), completionHandler: nil)
                    publishedShutter = currentShutter
                    publishedISO = normalizedState.manualISO
                }
            case .ap, .auto:
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }

                if capabilities.maxExposureBias > capabilities.minExposureBias {
                    let bias = exposureMode == .ap ? normalizedState.exposureBias : 0
                    device.setExposureTargetBias(Float(bias), completionHandler: nil)
                }

                publishedShutter = currentShutter
                publishedISO = currentISO
            }

            if normalizedState.focusMode == .manual && capabilities.supportsManualFocus {
                device.setFocusModeLocked(lensPosition: Float(normalizedState.lensPosition), completionHandler: nil)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }

            if effectiveWhiteBalanceMode == .manual && capabilities.supportsWhiteBalanceLock {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(normalizedState.whiteBalanceTemperature),
                    tint: 0
                )
                let gains = clampedWhiteBalanceGains(device.deviceWhiteBalanceGains(for: values), maxGain: device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }

            device.isSubjectAreaChangeMonitoringEnabled =
                !isFocusExposureLocked &&
                capabilities.supportsPointOfInterest &&
                (normalizedState.exposureMode.usesAutomaticExposureLoop || normalizedState.focusMode == .auto)
        }

        publishLiveExposure(shutter: publishedShutter, iso: publishedISO)

        publishOnMain {
            self.manualState = normalizedState
            self.persistPreferences()

            if announceWhiteBalanceOverride,
               currentMode == .constantColor,
               normalizedState.whiteBalanceMode == .manual {
                self.statusBanner = StatusBanner(
                    kind: .info,
                    message: "Constant Color uses auto white balance even when manual white balance is selected for Manual Photo."
                )
            }
        }
    }

    private func updateExposureProgramLoopOnQueue() {
        guard hasConfiguredSession else { return }

        let exposureMode = manualState.exposureMode
        guard exposureMode != .manual else {
            publishLiveExposure(shutter: manualState.manualShutterSeconds, iso: manualState.manualISO)
            return
        }

        withLockedDeviceOnQueue { device in
            let currentOffset = Double(device.exposureTargetOffset)
            let currentShutter = device.exposureDuration.seconds.clamped(to: capabilities.shutterRange)
            let currentISO = Double(device.iso).clamped(to: capabilities.isoRange)
            var publishedShutter = currentShutter
            var publishedISO = currentISO

            switch exposureMode {
            case .tv where capabilities.supportsManualExposure:
                let shutter = manualState.manualShutterSeconds.clamped(to: capabilities.shutterRange)
                let iso = adjustedProgramISO(currentISO: currentISO, offset: currentOffset)
                let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: duration, iso: Float(iso), completionHandler: nil)
                publishedShutter = shutter
                publishedISO = iso

            case .av where capabilities.supportsManualExposure:
                let iso = manualState.manualISO.clamped(to: capabilities.isoRange)
                let shutter = adjustedProgramShutter(currentShutter: currentShutter, offset: currentOffset)
                let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: duration, iso: Float(iso), completionHandler: nil)
                publishedShutter = shutter
                publishedISO = iso

            case .ap, .auto:
                publishedShutter = currentShutter
                publishedISO = currentISO

            case .manual, .tv, .av:
                break
            }

            self.publishLiveExposure(shutter: publishedShutter, iso: publishedISO)
        }
    }

    private func adjustedProgramISO(currentISO: Double, offset: Double) -> Double {
        guard offset.isFinite, abs(offset) > 0.05 else {
            return currentISO.clamped(to: capabilities.isoRange)
        }

        let adjustment = pow(2.0, max(-1.5, min(1.5, offset)) * 0.55)
        return (currentISO * adjustment).clamped(to: capabilities.isoRange)
    }

    private func adjustedProgramShutter(currentShutter: Double, offset: Double) -> Double {
        guard offset.isFinite, abs(offset) > 0.05 else {
            return currentShutter.clamped(to: capabilities.shutterRange)
        }

        let adjustment = pow(2.0, max(-1.5, min(1.5, offset)) * 0.55)
        return (currentShutter * adjustment).clamped(to: capabilities.shutterRange)
    }

    private func publishLiveExposure(shutter: Double, iso: Double) {
        publishOnMain {
            self.liveExposureShutterSeconds = shutter.clamped(to: self.capabilities.shutterRange)
            self.liveExposureISO = iso.clamped(to: self.capabilities.isoRange)
        }
    }

    private func handlePreviewPointOnQueue(_ point: CGPoint, lockExposureAndFocus: Bool) {
        guard hasConfiguredSession else { return }

        withLockedDeviceOnQueue { device in
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }

            if manualState.focusMode == .auto {
                if lockExposureAndFocus {
                    if capabilities.supportsManualFocus {
                        device.setFocusModeLocked(lensPosition: device.lensPosition, completionHandler: nil)
                    } else if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                } else if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }

            if manualState.exposureMode.usesAutomaticExposureLoop {
                if lockExposureAndFocus {
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }

                if capabilities.maxExposureBias > capabilities.minExposureBias {
                    let bias = manualState.exposureMode == .ap ? manualState.exposureBias : 0
                    device.setExposureTargetBias(Float(bias), completionHandler: nil)
                }
            }

            device.isSubjectAreaChangeMonitoringEnabled = !lockExposureAndFocus
        }

        publishOnMain {
            self.isFocusExposureLocked = lockExposureAndFocus
            self.statusBanner = StatusBanner(
                kind: .info,
                message: lockExposureAndFocus ? "AE/AF locked at the selected point." : "Metering moved to the selected point."
            )
        }
    }

    private func normalizedState(_ state: ManualControlState, capabilities: CaptureCapabilities) -> ManualControlState {
        var normalized = state

        if !capabilities.supportsManualExposure {
            normalized.exposureMode = .auto
        }

        if !capabilities.supportsManualFocus {
            normalized.focusMode = .auto
        }

        if !capabilities.supportsWhiteBalanceLock {
            normalized.whiteBalanceMode = .auto
        }

        normalized.exposureBias = normalized.exposureBias.clamped(to: capabilities.exposureBiasRange)
        normalized.manualISO = normalized.manualISO.clamped(to: capabilities.isoRange)
        normalized.manualShutterSeconds = normalized.manualShutterSeconds.clamped(to: capabilities.shutterRange)
        normalized.lensPosition = normalized.lensPosition.clamped(to: 0...1)
        normalized.whiteBalanceTemperature = normalized.whiteBalanceTemperature.clamped(to: 2_500...8_000)
        return normalized
    }

    private func resolveMode(_ mode: CaptureMode, capabilities: CaptureCapabilities) -> CaptureMode {
        mode == .constantColor && !capabilities.supportsConstantColor ? .manualPhoto : mode
    }

    private func resolveDriveMode(
        _ driveMode: CaptureDriveMode,
        mode: CaptureMode,
        capabilities: CaptureCapabilities
    ) -> CaptureDriveMode {
        if mode == .constantColor {
            return .single
        }

        switch driveMode {
        case .single:
            return .single
        case .bracket:
            return capabilities.maxBracketedCaptureCount >= 3 ? .bracket : .single
        case .longExposure:
            return capabilities.supportsManualExposure && capabilities.maxBracketedCaptureCount >= 2 ? .longExposure : .single
        }
    }

    private func normalizedLongExposureSeconds(
        _ seconds: Double,
        capabilities: CaptureCapabilities
    ) -> Double {
        let minimum = min(max(capabilities.minShutterSeconds, 0.25), capabilities.maxShutterSeconds)
        return seconds.clamped(to: minimum...capabilities.maxShutterSeconds)
    }

    private func resolvedLongExposurePlan() -> LongExposurePlan {
        switch selectedLongExposureMode {
        case .manual:
            return LongExposurePlan(
                shutterSeconds: normalizedLongExposureSeconds(selectedLongExposureSeconds, capabilities: capabilities),
                iso: resolvedLongExposureISO(),
                photoCount: max(2, min(capabilities.maxBracketedCaptureCount, 3)),
                stabilityDelayNanoseconds: UInt64(1.5 * Double(NSEC_PER_SEC))
            )
        case .nightAuto:
            return resolvedNightAutoExposurePlan()
        }
    }

    private func resolvedNightAutoExposurePlan() -> LongExposurePlan {
        let baseShutter = max(liveExposureShutterSeconds.clamped(to: capabilities.shutterRange), capabilities.minShutterSeconds)
        let baseISO = max(liveExposureISO.clamped(to: capabilities.isoRange), capabilities.minISO)
        let referenceShutter = max(ManualControlState.defaultShutterSeconds, capabilities.minShutterSeconds)
        let referenceISO = max(ManualControlState.defaultISO, capabilities.minISO)
        let darknessStops = log2(max(baseShutter / referenceShutter, 1.0)) + log2(max(baseISO / referenceISO, 1.0))

        let suggestedSeconds: Double
        let isoBias: Double
        let preferredCount: Int
        let stabilityDelaySeconds: Double

        switch selectedNightAutoPreset {
        case .handheld:
            switch darknessStops {
            case ..<1.5:
                suggestedSeconds = 0.25
            case ..<3.0:
                suggestedSeconds = 0.5
            default:
                suggestedSeconds = 1.0
            }
            isoBias = 0.96
            preferredCount = 2
            stabilityDelaySeconds = 1.2
        case .tripod:
            switch darknessStops {
            case ..<1.5:
                suggestedSeconds = 0.5
            case ..<3.5:
                suggestedSeconds = 1.0
            case ..<5.5:
                suggestedSeconds = 2.0
            default:
                suggestedSeconds = 4.0
            }
            isoBias = 0.78
            preferredCount = darknessStops >= 4.5 ? 3 : 2
            stabilityDelaySeconds = 2.4
        }

        let targetShutter = normalizedLongExposureSeconds(suggestedSeconds, capabilities: capabilities)
        let exposureProduct = baseShutter * baseISO
        let desiredISO = (exposureProduct / max(targetShutter, capabilities.minShutterSeconds)) * isoBias
        let targetISO = desiredISO.clamped(to: capabilities.isoRange)
        let minimumCount = min(capabilities.maxBracketedCaptureCount, 2)
        let targetPhotoCount = max(minimumCount, min(capabilities.maxBracketedCaptureCount, preferredCount))

        return LongExposurePlan(
            shutterSeconds: targetShutter,
            iso: targetISO,
            photoCount: targetPhotoCount,
            stabilityDelayNanoseconds: UInt64(stabilityDelaySeconds * Double(NSEC_PER_SEC))
        )
    }

    private func resolvedLongExposureISO() -> Double {
        let baseISO: Double
        switch manualState.exposureMode {
        case .manual, .av:
            baseISO = manualState.manualISO
        case .tv, .ap, .auto:
            baseISO = liveExposureISO
        }

        return baseISO.clamped(to: capabilities.isoRange)
    }

    private func persistPreferences() {
        let preferences = StoredPreferences(
            selectedMode: selectedMode,
            selectedDriveMode: selectedDriveMode,
            selectedLens: selectedLens,
            selectedSaveFormat: selectedSaveFormat,
            manualState: manualState,
            previewAssistState: previewAssistState,
            selectedLongExposureSeconds: selectedLongExposureSeconds,
            selectedLongExposureMode: selectedLongExposureMode,
            selectedNightAutoPreset: selectedNightAutoPreset
        )
        guard let encoded = try? JSONEncoder().encode(preferences) else { return }
        preferencesStore.set(encoded, forKey: Self.preferencesKey)
    }

    private func nightAutoPlanSummary(_ plan: LongExposurePlan) -> String {
        "\(formatShutter(plan.shutterSeconds)) · ISO \(Int(plan.iso.rounded())) · \(frameSummary(plan.photoCount))"
    }

    private func frameSummary(_ count: Int) -> String {
        count == 1 ? "1 frame" : "\(count) frames"
    }

    private func withLockedDeviceOnQueue(_ work: (AVCaptureDevice) -> Void) {
        guard let device = cameraDevice else { return }

        do {
            try device.lockForConfiguration()
            work(device)
            device.unlockForConfiguration()
        } catch {
            publishOnMain {
                self.statusBanner = StatusBanner(kind: .error, message: error.localizedDescription)
            }
        }
    }

    private func clampedWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains, maxGain: Float) -> AVCaptureDevice.WhiteBalanceGains {
        AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(1.0, gains.redGain), maxGain),
            greenGain: min(max(1.0, gains.greenGain), maxGain),
            blueGain: min(max(1.0, gains.blueGain), maxGain)
        )
    }

    private func applyVideoRotationAngleOnQueue() {
        applyVideoRotationAngle(videoRotationAngle, to: photoOutput.connection(with: .video))
        applyVideoRotationAngle(videoRotationAngle, to: videoDataOutput.connection(with: .video))
    }

    private func applyVideoRotationAngle(_ angle: CGFloat, to connection: AVCaptureConnection?) {
        guard let connection else { return }
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func handleCaptureCompletion(_ result: Result<CaptureResult, Error>) {
        publishOnMain {
            self.activeProcessor = nil
            self.isCaptureInProgress = false

            switch result {
            case .success(let captureResult):
                self.lastResult = captureResult
                self.statusBanner = StatusBanner(kind: .success, message: captureResult.message)
            case .failure(let error):
                self.statusBanner = StatusBanner(
                    kind: .error,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func publishOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }

        return "1/\(Int((1 / seconds).rounded()))"
    }

    private var effectiveWhiteBalanceMode: WhiteBalanceControlMode {
        selectedMode == .constantColor ? .auto : manualState.whiteBalanceMode
    }

    private var isSelectedModeSupported: Bool {
        selectedMode != .constantColor || capabilities.supportsConstantColor
    }

    private var isSelectedDriveModeSupported: Bool {
        switch selectedDriveMode {
        case .single:
            return true
        case .bracket:
            return supportsBracketCapture
        case .longExposure:
            return supportsLongExposure
        }
    }

    private var isRunningInSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }
}

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoDataOutput else { return }

        let assistState = previewAssistState
        let shouldUpdateExposureLoop = manualState.exposureMode != .manual
        guard assistState.showHistogram || assistState.showHighlightWarning || assistState.showFocusPeaking || shouldUpdateExposureLoop else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if timestamp.isFinite {
            guard timestamp - lastPreviewAnalysisTimestamp >= 0.16 else { return }
            lastPreviewAnalysisTimestamp = timestamp
        }

        if shouldUpdateExposureLoop {
            sessionQueue.async { [weak self] in
                self?.updateExposureProgramLoopOnQueue()
            }
        }

        guard assistState.showHistogram || assistState.showHighlightWarning || assistState.showFocusPeaking else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let analysis = analyzePreviewPixelBuffer(pixelBuffer, assistState: assistState)

        publishOnMain {
            self.histogramSnapshot = assistState.showHistogram ? analysis.histogram : .empty
            self.highlightWarningOverlay = assistState.showHighlightWarning ? analysis.highlightImage : nil
            self.focusPeakingOverlay = assistState.showFocusPeaking ? analysis.focusPeakingImage : nil
        }
    }

    private func analyzePreviewPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        assistState: PreviewAssistState
    ) -> PreviewAnalysisResult {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return PreviewAnalysisResult(histogram: .empty, highlightImage: nil, focusPeakingImage: nil)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        let histogramBinCount = HistogramSnapshot.empty.bins.count
        let analysisWidth = max(1, min(192, width))
        let stepX = max(1, width / analysisWidth)
        let stepY = max(1, height / max(1, Int(Double(height) * Double(analysisWidth) / Double(width))))
        let outputWidth = max(1, Int(ceil(Double(width) / Double(stepX))))
        let outputHeight = max(1, Int(ceil(Double(height) / Double(stepY))))

        var bins = Array(repeating: 0.0, count: histogramBinCount)
        var overlayPixels = assistState.showHighlightWarning
            ? Array(repeating: UInt8(0), count: outputWidth * outputHeight * 4)
            : []
        var lumaSamples = assistState.showFocusPeaking
            ? Array(repeating: 0.0, count: outputWidth * outputHeight)
            : []

        let highlightThreshold = 0.97
        let stripeSpan = 8

        var sampleCount = 0
        var highlightCount = 0
        var outputY = 0
        var y = 0

        while y < height {
            var outputX = 0
            var x = 0

            while x < width {
                let offset = y * bytesPerRow + x * 4
                let blue = Double(bytes[offset])
                let green = Double(bytes[offset + 1])
                let red = Double(bytes[offset + 2])
                let luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
                let sampleIndex = outputY * outputWidth + outputX
                if assistState.showFocusPeaking {
                    lumaSamples[sampleIndex] = luma
                }

                let histogramIndex = min(Int(luma * Double(histogramBinCount - 1)), histogramBinCount - 1)
                bins[histogramIndex] += 1
                sampleCount += 1

                let isClipped = luma >= highlightThreshold
                if isClipped {
                    highlightCount += 1
                }

                if assistState.showHighlightWarning && isClipped {
                    let pixelIndex = (outputY * outputWidth + outputX) * 4
                    let stripeOn = ((outputX + outputY) / stripeSpan).isMultiple(of: 2)
                    if stripeOn {
                        let alpha = UInt8(176)
                        let opacity = Double(alpha) / 255.0
                        overlayPixels[pixelIndex] = UInt8((255.0 * opacity).rounded())
                        overlayPixels[pixelIndex + 1] = UInt8((214.0 * opacity).rounded())
                        overlayPixels[pixelIndex + 2] = UInt8((72.0 * opacity).rounded())
                        overlayPixels[pixelIndex + 3] = alpha
                    }
                }

                x += stepX
                outputX += 1
            }

            y += stepY
            outputY += 1
        }

        guard sampleCount > 0 else {
            return PreviewAnalysisResult(histogram: .empty, highlightImage: nil, focusPeakingImage: nil)
        }

        let normalizedBins = normalizeHistogramBins(bins, sampleCount: sampleCount)
        let clippedRatio = Double(highlightCount) / Double(sampleCount)
        let histogram = HistogramSnapshot(bins: normalizedBins, clippedRatio: clippedRatio)
        let highlightImage = assistState.showHighlightWarning && highlightCount > 0
            ? makeOverlayImage(pixels: overlayPixels, width: outputWidth, height: outputHeight)
            : nil
        let focusPeakingImage = assistState.showFocusPeaking
            ? makeFocusPeakingOverlayImage(lumaSamples: lumaSamples, width: outputWidth, height: outputHeight)
            : nil

        return PreviewAnalysisResult(
            histogram: histogram,
            highlightImage: highlightImage,
            focusPeakingImage: focusPeakingImage
        )
    }

    private func normalizeHistogramBins(_ bins: [Double], sampleCount: Int) -> [Double] {
        let scaledBins = bins.map { $0 / Double(sampleCount) }
        let peak = scaledBins.max() ?? 0
        guard peak > 0 else { return scaledBins }
        return scaledBins.map { $0 / peak }
    }

    private func makeFocusPeakingOverlayImage(
        lumaSamples: [Double],
        width: Int,
        height: Int
    ) -> UIImage? {
        guard width > 2, height > 2 else { return nil }

        var pixels = Array(repeating: UInt8(0), count: width * height * 4)
        var peakCount = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let horizontal = abs(lumaSamples[index + 1] - lumaSamples[index - 1])
                let vertical = abs(lumaSamples[index + width] - lumaSamples[index - width])
                let magnitude = horizontal + vertical
                guard magnitude > 0.18 else { continue }

                let alpha = UInt8(min(220, max(96, Int(magnitude * 255.0))))
                let pixelIndex = index * 4
                pixels[pixelIndex] = 92
                pixels[pixelIndex + 1] = 242
                pixels[pixelIndex + 2] = 154
                pixels[pixelIndex + 3] = alpha
                peakCount += 1
            }
        }

        guard peakCount > 0 else { return nil }
        return makeOverlayImage(pixels: pixels, width: width, height: height)
    }

    private func makeOverlayImage(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> UIImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private struct PreviewAnalysisResult {
        let histogram: HistogramSnapshot
        let highlightImage: UIImage?
        let focusPeakingImage: UIImage?
    }
}

private extension CaptureService {
    static let preferencesKey = "camera-thing.v7.preferences"

    static func normalizedVideoRotationAngle(_ angle: CGFloat) -> CGFloat {
        let supportedAngles: [CGFloat] = [0, 90, 180, 270]
        return supportedAngles.min(by: { abs($0 - angle) < abs($1 - angle) }) ?? 90
    }

    static func loadPreferences(from store: UserDefaults) -> StoredPreferences? {
        guard let data = store.data(forKey: preferencesKey) else { return nil }
        return try? JSONDecoder().decode(StoredPreferences.self, from: data)
    }

    struct StoredPreferences: Codable {
        var selectedMode: CaptureMode = .manualPhoto
        var selectedDriveMode: CaptureDriveMode = .single
        var selectedLens: RearLens = .wide
        var selectedSaveFormat: CaptureSaveFormat = .heic
        var manualState: ManualControlState = .init()
        var previewAssistState: PreviewAssistState = .init()
        var selectedLongExposureSeconds: Double = 1.0
        var selectedLongExposureMode: LongExposureMode = .manual
        var selectedNightAutoPreset: NightAutoPreset = .handheld
    }

    struct LongExposurePlan {
        let shutterSeconds: Double
        let iso: Double
        let photoCount: Int
        let stabilityDelayNanoseconds: UInt64
    }

    struct CaptureRequest {
        let mode: CaptureMode
        let saveFormat: CaptureSaveFormat
        let settings: AVCapturePhotoSettings
        let expectedPhotoCount: Int
    }

    enum CaptureServiceError: LocalizedError {
        case rearCameraUnavailable
        case unableToAddInput
        case unableToAddOutput
        case unableToAddAnalysisOutput
        case unableToSwitchLens
        case constantColorUnavailable
        case bracketUnavailable
        case longExposureUnavailable
        case renderedCaptureUnavailable
        case longExposureRenderFailed

        var errorDescription: String? {
            switch self {
            case .rearCameraUnavailable:
                return "The rear main camera is unavailable on this device."
            case .unableToAddInput:
                return "The app couldn't attach the rear camera input."
            case .unableToAddOutput:
                return "The app couldn't attach the photo capture output."
            case .unableToAddAnalysisOutput:
                return "The app couldn't attach the live preview analysis output."
            case .unableToSwitchLens:
                return "The app couldn't switch to the selected rear lens."
            case .constantColorUnavailable:
                return "Constant Color isn't available on the current device or selected rear lens."
            case .bracketUnavailable:
                return "Exposure bracketing isn't available on the current camera configuration."
            case .longExposureUnavailable:
                return "Long Exposure needs manual shutter support and bracketed capture on the current rear lens."
            case .renderedCaptureUnavailable:
                return "Rendered photo capture isn't available as HEIC or JPEG on the current configuration."
            case .longExposureRenderFailed:
                return "The long exposure frames were captured, but the final composite couldn't be rendered."
            }
        }
    }

    enum CapturePersistence {
        static func writeTemporaryFile(data: Data, format: CaptureSaveFormat) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
            try data.write(to: url, options: .atomic)
            return url
        }

        static func writeCompositeFile(
            cgImage: CGImage,
            format: CaptureSaveFormat
        ) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
            let typeIdentifier = format == .heic ? UTType.heic.identifier : UTType.jpeg.identifier
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, 1, nil) else {
                throw CaptureServiceError.longExposureRenderFailed
            }

            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.96
            ]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

            guard CGImageDestinationFinalize(destination) else {
                throw CaptureServiceError.longExposureRenderFailed
            }

            return url
        }

        static func saveToPhotoLibrary(
            fileURL: URL,
            format: CaptureSaveFormat,
            filename: String,
            completion: @escaping (Result<String, Error>) -> Void
        ) {
            var placeholder: PHObjectPlaceholder?

            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                options.uniformTypeIdentifier = format.uniformTypeIdentifier
                creationRequest.addResource(with: .photo, fileURL: fileURL, options: options)
                placeholder = creationRequest.placeholderForCreatedAsset
            }, completionHandler: { success, error in
                try? FileManager.default.removeItem(at: fileURL)

                if let error {
                    completion(.failure(error))
                    return
                }

                guard success, let localIdentifier = placeholder?.localIdentifier else {
                    completion(.failure(CaptureProcessorError.saveFailed))
                    return
                }

                completion(.success(localIdentifier))
            })
        }

        static func makeFilename(
            mode: CaptureMode,
            format: CaptureSaveFormat,
            suffix: String? = nil
        ) -> String {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let prefix = mode == .manualPhoto ? "ManualPhoto" : "ConstantColor"
            if let suffix {
                return "CameraThing-\(prefix)-\(stamp)-\(suffix).\(format.fileExtension)"
            }
            return "CameraThing-\(prefix)-\(stamp).\(format.fileExtension)"
        }
    }

    enum CaptureProcessorError: LocalizedError {
        case missingFileData
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .missingFileData:
                return "The camera finished capturing, but no image data was returned."
            case .saveFailed:
                return "The photo couldn't be saved to your library."
            }
        }
    }

    final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
        private let mode: CaptureMode
        private let saveFormat: CaptureSaveFormat
        private let onWillSave: (CaptureSaveFormat) -> Void
        private let onComplete: (Result<CaptureResult, Error>) -> Void
        private let stateLock = NSLock()
        private var hasProcessedPhoto = false
        private var hasCompleted = false

        init(
            mode: CaptureMode,
            saveFormat: CaptureSaveFormat,
            onWillSave: @escaping (CaptureSaveFormat) -> Void,
            onComplete: @escaping (Result<CaptureResult, Error>) -> Void
        ) {
            self.mode = mode
            self.saveFormat = saveFormat
            self.onWillSave = onWillSave
            self.onComplete = onComplete
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error {
                finish(.failure(error))
                return
            }

            stateLock.lock()
            hasProcessedPhoto = true
            stateLock.unlock()

            guard let fileData = photo.fileDataRepresentation() else {
                finish(.failure(CaptureProcessorError.missingFileData))
                return
            }

            do {
                let temporaryURL = try CapturePersistence.writeTemporaryFile(data: fileData, format: saveFormat)
                onWillSave(saveFormat)
                let filename = CapturePersistence.makeFilename(mode: mode, format: saveFormat)
                CapturePersistence.saveToPhotoLibrary(
                    fileURL: temporaryURL,
                    format: saveFormat,
                    filename: filename
                ) { [weak self] result in
                    switch result {
                    case .success(let localIdentifier):
                        self?.finish(.success(CaptureResult(
                            mode: self?.mode ?? .manualPhoto,
                            fileFormat: self?.saveFormat ?? .jpeg,
                            localIdentifier: localIdentifier,
                            savedAssetCount: 1,
                            summaryMessage: nil
                        )))
                    case .failure(let error):
                        self?.finish(.failure(error))
                    }
                }
            } catch {
                finish(.failure(error))
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            guard let error else { return }

            stateLock.lock()
            let shouldFail = !hasProcessedPhoto
            stateLock.unlock()

            if shouldFail {
                finish(.failure(error))
            }
        }

        private func finish(_ result: Result<CaptureResult, Error>) {
            stateLock.lock()
            let alreadyCompleted = hasCompleted
            if !alreadyCompleted {
                hasCompleted = true
            }
            stateLock.unlock()

            guard !alreadyCompleted else { return }
            onComplete(result)
        }
    }

    final class BracketCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
        private let mode: CaptureMode
        private let saveFormat: CaptureSaveFormat
        private let expectedPhotoCount: Int
        private let onWillSave: (CaptureSaveFormat) -> Void
        private let onComplete: (Result<CaptureResult, Error>) -> Void
        private let stateLock = NSLock()
        private var localIdentifiers: [String] = []
        private var hasCompleted = false
        private var didAnnounceSave = false

        init(
            mode: CaptureMode,
            saveFormat: CaptureSaveFormat,
            expectedPhotoCount: Int,
            onWillSave: @escaping (CaptureSaveFormat) -> Void,
            onComplete: @escaping (Result<CaptureResult, Error>) -> Void
        ) {
            self.mode = mode
            self.saveFormat = saveFormat
            self.expectedPhotoCount = expectedPhotoCount
            self.onWillSave = onWillSave
            self.onComplete = onComplete
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error {
                finish(.failure(error))
                return
            }

            guard let fileData = photo.fileDataRepresentation() else {
                finish(.failure(CaptureProcessorError.missingFileData))
                return
            }

            do {
                let temporaryURL = try CapturePersistence.writeTemporaryFile(data: fileData, format: saveFormat)
                announceSaveIfNeeded()
                let sequence = max(photo.sequenceCount, 1)
                let filename = CapturePersistence.makeFilename(
                    mode: mode,
                    format: saveFormat,
                    suffix: String(format: "Bracket-%02d", sequence)
                )
                CapturePersistence.saveToPhotoLibrary(
                    fileURL: temporaryURL,
                    format: saveFormat,
                    filename: filename
                ) { [weak self] result in
                    switch result {
                    case .success(let localIdentifier):
                        self?.recordSavedAsset(localIdentifier: localIdentifier)
                    case .failure(let error):
                        self?.finish(.failure(error))
                    }
                }
            } catch {
                finish(.failure(error))
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            if let error {
                finish(.failure(error))
            }
        }

        private func announceSaveIfNeeded() {
            stateLock.lock()
            let shouldAnnounce = !didAnnounceSave
            if shouldAnnounce {
                didAnnounceSave = true
            }
            stateLock.unlock()

            if shouldAnnounce {
                onWillSave(saveFormat)
            }
        }

        private func recordSavedAsset(localIdentifier: String) {
            stateLock.lock()
            localIdentifiers.append(localIdentifier)
            let capturedIdentifiers = localIdentifiers
            stateLock.unlock()

            guard capturedIdentifiers.count == expectedPhotoCount else { return }

            finish(.success(CaptureResult(
                mode: mode,
                fileFormat: saveFormat,
                localIdentifier: capturedIdentifiers.first ?? "",
                savedAssetCount: capturedIdentifiers.count,
                summaryMessage: "Saved a three-shot \(saveFormat.rawValue) bracket to Photos."
            )))
        }

        private func finish(_ result: Result<CaptureResult, Error>) {
            stateLock.lock()
            let alreadyCompleted = hasCompleted
            if !alreadyCompleted {
                hasCompleted = true
            }
            stateLock.unlock()

            guard !alreadyCompleted else { return }
            onComplete(result)
        }
    }

    final class LongExposureCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
        private let mode: CaptureMode
        private let saveFormat: CaptureSaveFormat
        private let expectedPhotoCount: Int
        private let ciContext: CIContext
        private let captureLabel: String
        private let filenameSuffix: String
        private let onWillSave: (CaptureSaveFormat) -> Void
        private let onComplete: (Result<CaptureResult, Error>) -> Void
        private let stateLock = NSLock()
        private var photoDataBySequence: [Int: Data] = [:]
        private var hasCompleted = false
        private var didAnnounceSave = false
        private var didStartRender = false

        init(
            mode: CaptureMode,
            saveFormat: CaptureSaveFormat,
            expectedPhotoCount: Int,
            ciContext: CIContext,
            captureLabel: String,
            filenameSuffix: String,
            onWillSave: @escaping (CaptureSaveFormat) -> Void,
            onComplete: @escaping (Result<CaptureResult, Error>) -> Void
        ) {
            self.mode = mode
            self.saveFormat = saveFormat
            self.expectedPhotoCount = expectedPhotoCount
            self.ciContext = ciContext
            self.captureLabel = captureLabel
            self.filenameSuffix = filenameSuffix
            self.onWillSave = onWillSave
            self.onComplete = onComplete
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error {
                finish(.failure(error))
                return
            }

            guard let fileData = photo.fileDataRepresentation() else {
                finish(.failure(CaptureProcessorError.missingFileData))
                return
            }

            let sequence = max(photo.sequenceCount, photoDataBySequence.count + 1)
            stateLock.lock()
            photoDataBySequence[sequence] = fileData
            let shouldRender = photoDataBySequence.count == expectedPhotoCount && !didStartRender
            if shouldRender {
                didStartRender = true
            }
            stateLock.unlock()

            guard shouldRender else { return }

            announceSaveIfNeeded()

            do {
                let orderedData = (1...expectedPhotoCount).compactMap { photoDataBySequence[$0] }
                guard orderedData.count == expectedPhotoCount else {
                    throw CaptureServiceError.longExposureRenderFailed
                }

                guard let compositeImage = makeCompositeImage(from: orderedData) else {
                    throw CaptureServiceError.longExposureRenderFailed
                }

                let temporaryURL = try CapturePersistence.writeCompositeFile(cgImage: compositeImage, format: saveFormat)
                let filename = CapturePersistence.makeFilename(mode: mode, format: saveFormat, suffix: filenameSuffix)
                CapturePersistence.saveToPhotoLibrary(
                    fileURL: temporaryURL,
                    format: saveFormat,
                    filename: filename
                ) { [weak self] result in
                    switch result {
                    case .success(let localIdentifier):
                        self?.finish(.success(CaptureResult(
                            mode: self?.mode ?? .manualPhoto,
                            fileFormat: self?.saveFormat ?? .jpeg,
                            localIdentifier: localIdentifier,
                            savedAssetCount: 1,
                            summaryMessage: "Saved a stacked \(self?.captureLabel.lowercased() ?? "long exposure") \(self?.saveFormat.rawValue ?? "JPEG") to Photos."
                        )))
                    case .failure(let error):
                        self?.finish(.failure(error))
                    }
                }
            } catch {
                finish(.failure(error))
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            if let error {
                finish(.failure(error))
            }
        }

        private func announceSaveIfNeeded() {
            stateLock.lock()
            let shouldAnnounce = !didAnnounceSave
            if shouldAnnounce {
                didAnnounceSave = true
            }
            stateLock.unlock()

            if shouldAnnounce {
                onWillSave(saveFormat)
            }
        }

        private func makeCompositeImage(from dataItems: [Data]) -> CGImage? {
            let images = dataItems.compactMap { CIImage(data: $0) }
            guard let firstImage = images.first else { return nil }
            let extent = firstImage.extent
            let weight = 1.0 / Double(images.count)
            let zeroImage = CIImage(color: .black).cropped(to: extent)

            let composite = images.reduce(zeroImage) { partial, image in
                let weighted = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: weight, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: weight, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: weight, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ])

                return weighted.applyingFilter("CIAdditionCompositing", parameters: [
                    kCIInputBackgroundImageKey: partial
                ])
            }

            return ciContext.createCGImage(composite, from: extent)
        }

        private func finish(_ result: Result<CaptureResult, Error>) {
            stateLock.lock()
            let alreadyCompleted = hasCompleted
            if !alreadyCompleted {
                hasCompleted = true
            }
            stateLock.unlock()

            guard !alreadyCompleted else { return }
            onComplete(result)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
