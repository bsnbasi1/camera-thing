import SwiftUI

struct CameraScreen: View {
    private enum QuickPanel: String, CaseIterable, Identifiable {
        case lens
        case exposure
        case focus
        case whiteBalance
        case more

        var id: Self { self }

        var title: String {
            switch self {
            case .lens:
                return "Lens"
            case .exposure:
                return "Exposure"
            case .focus:
                return "Focus"
            case .whiteBalance:
                return "White Balance"
            case .more:
                return "More"
            }
        }

        var shortLabel: String {
            switch self {
            case .lens:
                return "Lens"
            case .exposure:
                return "Exp"
            case .focus:
                return "Focus"
            case .whiteBalance:
                return "WB"
            case .more:
                return "More"
            }
        }

        var icon: String {
            switch self {
            case .lens:
                return "camera.macro.circle"
            case .exposure:
                return "plusminus.circle"
            case .focus:
                return "scope"
            case .whiteBalance:
                return "thermometer.sun"
            case .more:
                return "slider.horizontal.3"
            }
        }
    }

    private struct OverlayNotice {
        let title: String
        let message: String
        let tint: Color
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
    }

    private struct FocusReticle: Identifiable, Equatable {
        let id = UUID()
        let point: CGPoint
        let isLocked: Bool
    }

    private struct AssistShortcut: Identifiable {
        let id: String
        let title: String
        let disable: () -> Void
    }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var captureService = CaptureService()
    @State private var activePanel: QuickPanel?
    @State private var focusReticle: FocusReticle?

    private let accentColor = Color(red: 0.98, green: 0.76, blue: 0.24)
    private let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.01, green: 0.01, blue: 0.02),
            Color(red: 0.04, green: 0.05, blue: 0.07),
            Color(red: 0.07, green: 0.06, blue: 0.05)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        GeometryReader { proxy in
            let compactUI = isCompactPhoneHeight(proxy.size.height)
            let isLandscape = proxy.size.width > proxy.size.height

            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                previewSurface(compactUI: compactUI, isLandscape: isLandscape)

                topChrome(safeAreaTop: proxy.safeAreaInsets.top, compactUI: compactUI, isLandscape: isLandscape)

                if let notice = overlayNotice {
                    overlayNoticeCard(notice)
                        .frame(maxWidth: isLandscape ? min(proxy.size.width * 0.52, 420) : min(proxy.size.width - 24, 520))
                        .padding(.horizontal, compactUI ? 12 : 16)
                        .padding(.top, proxy.safeAreaInsets.top + (isLandscape ? 44 : (compactUI ? 48 : 56)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                bottomChrome(
                    safeAreaInsets: proxy.safeAreaInsets,
                    drawerHeight: drawerHeight(for: proxy.size, isLandscape: isLandscape),
                    compactUI: compactUI,
                    isLandscape: isLandscape,
                    availableWidth: proxy.size.width
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .animation(.easeInOut(duration: 0.22), value: activePanel)
            .animation(.easeInOut(duration: 0.22), value: captureService.statusBanner?.message)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            captureService.prepare()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                captureService.prepare()
            case .background:
                captureService.pause()
            default:
                break
            }
        }
    }

    private func previewSurface(compactUI: Bool, isLandscape: Bool) -> some View {
        ZStack {
            if captureService.cameraPermission.isAuthorized && captureService.isSessionConfigured {
                ZStack {
                    CameraPreview(
                        session: captureService.session,
                        onTap: { interaction in
                            closeActivePanel()
                            showFocusReticle(at: interaction.viewPoint, locked: false)
                            captureService.handlePreviewTap(at: interaction.devicePoint)
                        },
                        onLongPress: { interaction in
                            closeActivePanel()
                            showFocusReticle(at: interaction.viewPoint, locked: true)
                            captureService.handlePreviewLongPress(at: interaction.devicePoint)
                        },
                        onRotationAngleChange: { angle in
                            captureService.setVideoRotationAngle(angle)
                        }
                    )
                    .ignoresSafeArea()

                    if let overlay = captureService.highlightWarningOverlay,
                       captureService.previewAssistState.showHighlightWarning {
                        Image(uiImage: overlay)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFill()
                            .blendMode(.plusLighter)
                            .opacity(0.90)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                    if let overlay = captureService.focusPeakingOverlay,
                       captureService.previewAssistState.showFocusPeaking {
                        Image(uiImage: overlay)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFill()
                            .blendMode(.screen)
                            .opacity(0.88)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                    if captureService.previewAssistState.showGrid {
                        previewGridOverlay
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }

                    if let focusReticle {
                        focusReticleOverlay(focusReticle)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
            } else {
                placeholderPreview
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeActivePanel()
                    }
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(0.14),
                    .clear,
                    Color.black.opacity(0.22)
                ],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.78)
                ],
                startPoint: .center,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if captureService.previewAssistState.showHistogram && captureService.histogramSnapshot.hasSignal {
                histogramOverlay
                    .padding(.top, isLandscape ? 58 : (compactUI ? 82 : 96))
                    .padding(.trailing, compactUI ? 12 : 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if captureService.previewAssistState.showLevel {
                levelOverlay
                    .padding(.top, isLandscape ? 60 : (compactUI ? 84 : 100))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func topChrome(safeAreaTop: CGFloat, compactUI: Bool, isLandscape: Bool) -> some View {
        HStack {
            topEdgeAccessory(compactUI: compactUI)
                .frame(width: isLandscape ? 132 : (compactUI ? 84 : 104), alignment: .leading)

            Spacer(minLength: compactUI ? 8 : 12)

            topModeBadge(compactUI: compactUI)

            Spacer(minLength: compactUI ? 8 : 12)

            topFormatBadge(compactUI: compactUI)
                .frame(width: isLandscape ? 96 : (compactUI ? 84 : 104), alignment: .trailing)
        }
        .padding(.horizontal, compactUI ? 12 : 16)
        .padding(.top, safeAreaTop + (isLandscape ? 4 : (compactUI ? 6 : 10)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func topEdgeAccessory(compactUI: Bool) -> some View {
        if captureService.isFocusExposureLocked {
            smallBadge("LOCK", icon: "lock.fill", tint: accentColor, compactUI: compactUI)
        } else if !activeAssistSummary.isEmpty {
            Button {
                togglePanel(.more)
            } label: {
                smallBadge(activeAssistBadgeText(compactUI: compactUI), icon: "viewfinder", tint: .white.opacity(0.92), compactUI: compactUI)
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(height: compactUI ? 30 : 34)
        }
    }

    private func topModeBadge(compactUI: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: captureService.selectedMode == .constantColor ? "sparkles.square.filled.on.square" : "camera.aperture")
                .font(.system(size: compactUI ? 11 : 12, weight: .semibold))
            Text(compactUI ? captureService.selectedMode.shortTitle : captureService.selectedMode.title)
                .font(.system(compactUI ? .caption : .subheadline, design: .rounded).weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compactUI ? 12 : 14)
        .padding(.vertical, compactUI ? 8 : 10)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func topFormatBadge(compactUI: Bool) -> some View {
        smallBadge(captureService.selectedSaveFormat.rawValue, icon: "photo", tint: .white.opacity(0.92), compactUI: compactUI)
    }

    @ViewBuilder
    private func bottomChrome(
        safeAreaInsets: EdgeInsets,
        drawerHeight: CGFloat,
        compactUI: Bool,
        isLandscape: Bool,
        availableWidth: CGFloat
    ) -> some View {
        if isLandscape {
            landscapeBottomChrome(
                safeAreaInsets: safeAreaInsets,
                drawerHeight: drawerHeight,
                availableWidth: availableWidth
            )
        } else {
            portraitBottomChrome(
                safeAreaBottom: max(safeAreaInsets.bottom, 14),
                drawerHeight: drawerHeight,
                compactUI: compactUI
            )
        }
    }

    private func portraitBottomChrome(safeAreaBottom: CGFloat, drawerHeight: CGFloat, compactUI: Bool) -> some View {
        VStack(spacing: compactUI ? 8 : 12) {
            if let activePanel {
                quickPanelDrawer(for: activePanel, compactUI: compactUI, isLandscape: false)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: drawerHeight, alignment: .top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            cameraProgramRail(compactUI: compactUI)

            if shouldShowStatusHUD(compactUI: compactUI, isLandscape: false) {
                compactStatusHUD(compactUI: compactUI)
            }

            if hasActiveAssistShortcuts {
                activeAssistShortcutBar(compactUI: compactUI, isLandscape: false)
            }

            toolRail(compactUI: compactUI)

            shutterDock(compactUI: compactUI, isLandscape: false)
        }
        .padding(.horizontal, compactUI ? 12 : 16)
        .padding(.top, compactUI ? (activePanel == nil ? 6 : 4) : (activePanel == nil ? 10 : 6))
        .padding(.bottom, safeAreaBottom)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func landscapeBottomChrome(
        safeAreaInsets: EdgeInsets,
        drawerHeight: CGFloat,
        availableWidth: CGFloat
    ) -> some View {
        let compactUI = true
        let rowMaxWidth = min(max(availableWidth * 0.34, 210), 300)
        let drawerMaxWidth = min(availableWidth - (safeAreaInsets.leading + safeAreaInsets.trailing) - 24, 760)

        return VStack(spacing: 8) {
            if let activePanel {
                quickPanelDrawer(for: activePanel, compactUI: compactUI, isLandscape: true)
                    .frame(maxWidth: drawerMaxWidth)
                    .frame(minHeight: drawerHeight, alignment: .top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 12) {
                cameraProgramRail(compactUI: compactUI)
                    .frame(maxWidth: rowMaxWidth)

                Spacer(minLength: 0)

                shutterDock(compactUI: compactUI, isLandscape: true)

                Spacer(minLength: 0)

                toolRail(compactUI: compactUI)
                    .frame(maxWidth: rowMaxWidth)
            }

            if shouldShowStatusHUD(compactUI: compactUI, isLandscape: true) || hasActiveAssistShortcuts {
                HStack(spacing: 10) {
                    if shouldShowStatusHUD(compactUI: compactUI, isLandscape: true) {
                        compactStatusHUD(compactUI: compactUI)
                            .frame(maxWidth: min(max(availableWidth * 0.36, 240), 360))
                    }

                    if hasActiveAssistShortcuts {
                        activeAssistShortcutBar(compactUI: compactUI, isLandscape: true)
                            .frame(maxWidth: min(max(availableWidth * 0.38, 260), 420))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, max(safeAreaInsets.leading, 12))
        .padding(.trailing, max(safeAreaInsets.trailing, 12))
        .padding(.top, activePanel == nil ? 8 : 4)
        .padding(.bottom, max(safeAreaInsets.bottom, 10))
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private func quickPanelDrawer(for panel: QuickPanel, compactUI: Bool, isLandscape: Bool) -> some View {
        drawerContainer(title: panel.title, note: panelNote(for: panel), compactUI: compactUI, isLandscape: isLandscape) {
            switch panel {
            case .lens:
                HStack(spacing: compactUI ? 8 : 10) {
                    ForEach(captureService.capabilities.availableLenses) { lens in
                        pillButton(
                            lens.title,
                            selected: captureService.selectedLens == lens,
                            compactUI: compactUI,
                            disabled: isPreviewControlDisabled,
                            action: { captureService.selectLens(lens) }
                        )
                    }
                }

            case .exposure:
                VStack(alignment: .leading, spacing: compactUI ? 10 : 12) {
                    switch captureService.manualState.exposureMode {
                    case .auto:
                        miniHint("Full auto handles both shutter and ISO for you.", compactUI: compactUI)

                    case .ap:
                        drawerSlider(
                            title: "EV Bias",
                            valueText: exposureBiasText,
                            value: exposureBiasBinding,
                            range: captureService.capabilities.exposureBiasRange,
                            compactUI: compactUI
                        )

                    case .av:
                        drawerSlider(
                            title: "ISO",
                            valueText: "ISO \(Int(captureService.manualState.manualISO.rounded()))",
                            value: isoBinding,
                            range: captureService.capabilities.isoRange,
                            compactUI: compactUI
                        )

                    case .tv:
                        drawerSlider(
                            title: "Shutter",
                            valueText: formatShutter(captureService.manualState.manualShutterSeconds),
                            value: shutterSliderBinding,
                            range: shutterLogRange,
                            compactUI: compactUI
                        )

                    case .manual:
                        VStack(spacing: compactUI ? 8 : 10) {
                            drawerSlider(
                                title: "Shutter",
                                valueText: formatShutter(captureService.manualState.manualShutterSeconds),
                                value: shutterSliderBinding,
                                range: shutterLogRange,
                                compactUI: compactUI
                            )

                            drawerSlider(
                                title: "ISO",
                                valueText: "ISO \(Int(captureService.manualState.manualISO.rounded()))",
                                value: isoBinding,
                                range: captureService.capabilities.isoRange,
                                compactUI: compactUI
                            )
                        }
                    }
                }

            case .focus:
                VStack(alignment: .leading, spacing: compactUI ? 10 : 12) {
                    compactModePicker(
                        autoTitle: "Auto",
                        manualTitle: "Manual",
                        autoSelected: captureService.manualState.focusMode == .auto,
                        manualSelected: captureService.manualState.focusMode == .manual,
                        compactUI: compactUI,
                        manualDisabled: isPreviewControlDisabled || !captureService.capabilities.supportsManualFocus,
                        onSelectAuto: { captureService.setFocusMode(.auto) },
                        onSelectManual: { captureService.setFocusMode(.manual) }
                    )

                    if captureService.manualState.focusMode == .manual {
                        drawerSlider(
                            title: "Lens Position",
                            valueText: "\(Int((captureService.manualState.lensPosition * 100).rounded()))%",
                            value: lensPositionBinding,
                            range: 0...1,
                            compactUI: compactUI
                        )
                    } else {
                        miniHint("Tap to meter. Hold to lock AE/AF when supported.", compactUI: compactUI)
                    }
                }

            case .whiteBalance:
                VStack(alignment: .leading, spacing: compactUI ? 10 : 12) {
                    compactModePicker(
                        autoTitle: "Auto",
                        manualTitle: "Manual",
                        autoSelected: displayedWhiteBalanceMode == .auto,
                        manualSelected: displayedWhiteBalanceMode == .manual,
                        compactUI: compactUI,
                        manualDisabled: isPreviewControlDisabled || captureService.selectedMode == .constantColor || !captureService.capabilities.supportsWhiteBalanceLock,
                        onSelectAuto: { captureService.setWhiteBalanceMode(.auto) },
                        onSelectManual: { captureService.setWhiteBalanceMode(.manual) }
                    )

                    if displayedWhiteBalanceMode == .manual {
                        drawerSlider(
                            title: "Temperature",
                            valueText: "\(Int(captureService.manualState.whiteBalanceTemperature.rounded()))K",
                            value: whiteBalanceBinding,
                            range: 2_500...8_000,
                            compactUI: compactUI
                        )
                    }
                }

            case .more:
                VStack(alignment: .leading, spacing: compactUI ? 10 : 12) {
                    drawerRow(title: "Mode") {
                        HStack(spacing: compactUI ? 8 : 10) {
                            pillButton(
                                "Manual",
                                selected: captureService.selectedMode == .manualPhoto,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled,
                                action: { captureService.selectMode(.manualPhoto) }
                            )

                            pillButton(
                                "Constant",
                                selected: captureService.selectedMode == .constantColor,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled || !captureService.capabilities.supportsConstantColor,
                                action: { captureService.selectMode(.constantColor) }
                            )
                        }
                    }

                    drawerRow(title: "Shot") {
                        HStack(spacing: compactUI ? 8 : 10) {
                            ForEach(CaptureDriveMode.allCases) { driveMode in
                                pillButton(
                                    driveMode.title,
                                    selected: captureService.selectedDriveMode == driveMode,
                                    compactUI: compactUI,
                                    disabled: isPreviewControlDisabled || isDriveModeDisabled(driveMode),
                                    action: { captureService.selectDriveMode(driveMode) }
                                )
                            }
                        }
                    }

                    if captureService.selectedDriveMode == .longExposure {
                        drawerRow(title: "Style") {
                            HStack(spacing: compactUI ? 8 : 10) {
                                ForEach(LongExposureMode.allCases) { longExposureMode in
                                    pillButton(
                                        longExposureMode.title,
                                        selected: captureService.selectedLongExposureMode == longExposureMode,
                                        compactUI: compactUI,
                                        disabled: isPreviewControlDisabled || !captureService.supportsLongExposure,
                                        action: { captureService.setLongExposureMode(longExposureMode) }
                                    )
                                }
                            }
                        }

                        if captureService.selectedLongExposureMode == .manual {
                            drawerRow(title: "Long Exposure") {
                                HStack(spacing: compactUI ? 8 : 10) {
                                    ForEach(captureService.longExposureChoices, id: \.self) { option in
                                        pillButton(
                                            formatShutter(option),
                                            selected: abs(captureService.selectedLongExposureSeconds - option) < 0.05,
                                            compactUI: compactUI,
                                            disabled: isPreviewControlDisabled || !captureService.supportsLongExposure,
                                            action: { captureService.setLongExposureSeconds(option) }
                                        )
                                    }
                                }
                            }
                        } else {
                            drawerRow(title: "Night Auto") {
                                VStack(alignment: .leading, spacing: compactUI ? 8 : 10) {
                                    HStack(spacing: compactUI ? 8 : 10) {
                                        ForEach(NightAutoPreset.allCases) { preset in
                                            pillButton(
                                                preset.title,
                                                selected: captureService.selectedNightAutoPreset == preset,
                                                compactUI: compactUI,
                                                disabled: isPreviewControlDisabled || !captureService.supportsLongExposure,
                                                action: { captureService.setNightAutoPreset(preset) }
                                            )
                                        }
                                    }

                                    LazyVGrid(
                                        columns: [GridItem(.adaptive(minimum: isLandscape ? 110 : 124), spacing: compactUI ? 8 : 10)],
                                        spacing: compactUI ? 8 : 10
                                    ) {
                                        readoutPill(
                                            title: "Preset",
                                            value: captureService.selectedNightAutoPreset.title,
                                            compactUI: compactUI
                                        )

                                        readoutPill(
                                            title: "Metering",
                                            value: captureService.nightAutoPlanReadout,
                                            compactUI: compactUI
                                        )
                                    }

                                    miniHint(
                                        captureService.selectedNightAutoPreset == .handheld
                                            ? "Handheld keeps Night Auto shorter and quicker. It re-checks the scene when you press the shutter."
                                            : "Tripod allows longer shutters and cleaner ISO. It re-checks the scene when you press the shutter.",
                                        compactUI: compactUI
                                    )
                                }
                            }
                        }
                    }

                    drawerRow(title: "Format") {
                        HStack(spacing: compactUI ? 8 : 10) {
                            ForEach(CaptureSaveFormat.allCases) { format in
                                pillButton(
                                    format.rawValue,
                                    selected: captureService.selectedSaveFormat == format,
                                    compactUI: compactUI,
                                    disabled: isPreviewControlDisabled || !captureService.capabilities.availableSaveFormats.contains(format),
                                    action: { captureService.selectSaveFormat(format) }
                                )
                            }
                        }
                    }

                    drawerRow(title: "Assist") {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: compactUI ? 8 : 10),
                                count: isLandscape ? 5 : 3
                            ),
                            spacing: compactUI ? 8 : 10
                        ) {
                            togglePill(
                                "Grid",
                                active: captureService.previewAssistState.showGrid,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled,
                                action: { captureService.setGridEnabled(!captureService.previewAssistState.showGrid) }
                            )

                            togglePill(
                                "Histogram",
                                active: captureService.previewAssistState.showHistogram,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled,
                                action: { captureService.setHistogramEnabled(!captureService.previewAssistState.showHistogram) }
                            )

                            togglePill(
                                "Zebra",
                                active: captureService.previewAssistState.showHighlightWarning,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled,
                                action: { captureService.setHighlightWarningEnabled(!captureService.previewAssistState.showHighlightWarning) }
                            )

                            togglePill(
                                "Peaking",
                                active: captureService.previewAssistState.showFocusPeaking,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled,
                                action: { captureService.setFocusPeakingEnabled(!captureService.previewAssistState.showFocusPeaking) }
                            )

                            togglePill(
                                "Level",
                                active: captureService.previewAssistState.showLevel,
                                compactUI: compactUI,
                                disabled: isPreviewControlDisabled,
                                action: { captureService.setLevelEnabled(!captureService.previewAssistState.showLevel) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func cameraProgramRail(compactUI: Bool) -> some View {
        HStack(spacing: compactUI ? 6 : 8) {
            ForEach(ExposureControlMode.allCases) { mode in
                exposureModeButton(mode, compactUI: compactUI)
            }
        }
        .padding(.horizontal, compactUI ? 8 : 10)
        .padding(.vertical, compactUI ? 6 : 8)
        .background(.black.opacity(0.34), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func compactStatusHUD(compactUI: Bool) -> some View {
        if compactUI {
            Text(compactHUDLine)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.38), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        } else {
            HStack(spacing: 10) {
                ForEach(Array(hudItems.enumerated()), id: \.offset) { entry in
                    if entry.offset > 0 {
                        Circle()
                            .fill(.white.opacity(0.28))
                            .frame(width: 3, height: 3)
                    }

                    Text(entry.element)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.42), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private func activeAssistShortcutBar(compactUI: Bool, isLandscape: Bool) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: isLandscape ? 64 : 72, maximum: isLandscape ? 94 : 108), spacing: compactUI ? 6 : 8)],
            spacing: compactUI ? 6 : 8
        ) {
            ForEach(activeAssistShortcuts) { shortcut in
                assistShortcutButton(shortcut, compactUI: compactUI)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compactUI ? 8 : 10)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func assistShortcutButton(_ shortcut: AssistShortcut, compactUI: Bool) -> some View {
        Button {
            shortcut.disable()
        } label: {
            HStack(spacing: 5) {
                Text(shortcut.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: compactUI ? 11 : 12, weight: .bold))
            }
            .font(.system(compactUI ? .caption2 : .caption, design: .rounded).weight(.semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compactUI ? 8 : 9)
            .padding(.horizontal, compactUI ? 8 : 10)
            .background(accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func exposureModeButton(_ mode: ExposureControlMode, compactUI: Bool) -> some View {
        let isSelected = captureService.manualState.exposureMode == mode

        return Button {
            captureService.setExposureMode(mode)
        } label: {
            Text(mode.title)
                .font(.system(compactUI ? .caption2 : .caption, design: .rounded).weight(.bold))
                .foregroundStyle(isSelected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compactUI ? 7 : 9)
                .background(
                    Capsule()
                        .fill(isSelected ? accentColor : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(isPreviewControlDisabled || (mode.requiresManualExposureSupport && !captureService.capabilities.supportsManualExposure))
        .opacity((isPreviewControlDisabled || (mode.requiresManualExposureSupport && !captureService.capabilities.supportsManualExposure)) ? 0.45 : 1.0)
    }

    private func toolRail(compactUI: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(QuickPanel.allCases) { panel in
                compactToolButton(panel, compactUI: compactUI)
            }
        }
        .padding(.horizontal, compactUI ? 6 : 8)
        .padding(.vertical, compactUI ? 6 : 8)
        .background(.black.opacity(0.34), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func shutterDock(compactUI: Bool, isLandscape: Bool) -> some View {
        let innerSize = isLandscape ? 68.0 : (compactUI ? 76.0 : 90.0)
        let ringSize = isLandscape ? 84.0 : (compactUI ? 92.0 : 106.0)
        let accentSize = isLandscape ? 40.0 : (compactUI ? 44.0 : 54.0)
        let frameSize = isLandscape ? 92.0 : (compactUI ? 100.0 : 116.0)

        return VStack(spacing: 8) {
            Button {
                captureService.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(captureService.canCapture ? 0.98 : 0.24))
                        .frame(width: innerSize, height: innerSize)

                    Circle()
                        .strokeBorder(.white.opacity(0.42), lineWidth: 3)
                        .frame(width: ringSize, height: ringSize)

                    if captureService.isCaptureInProgress {
                        ProgressView()
                            .tint(.black)
                            .scaleEffect(compactUI ? 0.98 : 1.08)
                    } else {
                        Circle()
                            .fill(captureService.canCapture ? accentColor : .gray.opacity(0.35))
                            .frame(width: accentSize, height: accentSize)
                    }
                }
                .frame(width: frameSize, height: frameSize)
            }
            .buttonStyle(.plain)
            .disabled(!captureService.canCapture)

            if let footerStatusText {
                Text(footerStatusText)
                    .font(.system(compactUI ? .caption2 : .caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(isLandscape ? 1 : (compactUI ? 1 : 2))
                    .frame(maxWidth: isLandscape ? 180 : .infinity)
            }
        }
    }

    private func compactToolButton(_ panel: QuickPanel, compactUI: Bool) -> some View {
        let isSelected = activePanel == panel

        return Button {
            togglePanel(panel)
        } label: {
            VStack(spacing: compactUI ? 2 : 5) {
                ZStack {
                    Circle()
                        .fill(isSelected ? accentColor : Color.white.opacity(0.08))
                        .frame(width: compactUI ? 36 : 42, height: compactUI ? 36 : 42)

                    Image(systemName: panel.icon)
                        .font(.system(size: compactUI ? 16 : 18, weight: .semibold))
                        .foregroundStyle(isSelected ? .black : .white)
                }

                if !compactUI {
                    Text(panel.shortLabel)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.74))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compactUI ? 2 : 4)
        }
        .buttonStyle(.plain)
        .disabled(isPreviewControlDisabled)
        .opacity(isPreviewControlDisabled ? 0.48 : 1.0)
    }

    private func drawerContainer<Content: View>(
        title: String,
        note: String?,
        compactUI: Bool,
        isLandscape: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let denseLayout = compactUI || isLandscape

        return VStack(alignment: .leading, spacing: denseLayout ? 8 : 12) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: denseLayout ? 34 : 42, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)

            HStack {
                Text(title)
                    .font(.system(denseLayout ? .subheadline : .headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                if let drawerValue = drawerValueText(for: activePanel) {
                    Text(drawerValue)
                        .font(.system(denseLayout ? .caption : .footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            content()

            if let note {
                miniHint(note, compactUI: denseLayout)
            }
        }
        .padding(.horizontal, denseLayout ? 12 : 16)
        .padding(.top, denseLayout ? 8 : 10)
        .padding(.bottom, denseLayout ? 12 : 14)
        .background(.black.opacity(isLandscape ? 0.62 : 0.56), in: RoundedRectangle(cornerRadius: denseLayout ? 24 : 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: denseLayout ? 24 : 28, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func compactModePicker(
        autoTitle: String,
        manualTitle: String,
        autoSelected: Bool,
        manualSelected: Bool,
        compactUI: Bool,
        manualDisabled: Bool,
        onSelectAuto: @escaping () -> Void,
        onSelectManual: @escaping () -> Void
    ) -> some View {
        HStack(spacing: compactUI ? 8 : 10) {
            pillButton(
                autoTitle,
                selected: autoSelected,
                compactUI: compactUI,
                disabled: isPreviewControlDisabled,
                action: onSelectAuto
            )

            pillButton(
                manualTitle,
                selected: manualSelected,
                compactUI: compactUI,
                disabled: manualDisabled,
                action: onSelectManual
            )
        }
    }

    private func drawerSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        compactUI: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(compactUI ? .footnote : .subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text(valueText)
                    .font(.system(compactUI ? .caption : .footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Slider(value: value, in: range)
                .tint(accentColor)
                .disabled(isPreviewControlDisabled)
        }
        .padding(compactUI ? 10 : 12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func drawerRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.64))

            content()
        }
    }

    private func readoutPill(title: String, value: String, compactUI: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)

            Text(value)
                .font(.system(compactUI ? .caption : .footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compactUI ? 10 : 12)
        .padding(.vertical, compactUI ? 9 : 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func pillButton(
        _ title: String,
        selected: Bool,
        compactUI: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(compactUI ? .footnote : .subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compactUI ? 9 : 11)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(selected ? accentColor : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.0 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }

    private func togglePill(
        _ title: String,
        active: Bool,
        compactUI: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(compactUI ? .footnote : .subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(active ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compactUI ? 9 : 11)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(active ? accentColor : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(active ? 0.0 : 0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }

    private func smallBadge(_ title: String, icon: String, tint: Color, compactUI: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: compactUI ? 10 : 11, weight: .semibold))
            Text(title)
                .font(.system(compactUI ? .caption2 : .caption, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, compactUI ? 8 : 10)
        .padding(.vertical, compactUI ? 6 : 8)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func overlayNoticeCard(_ notice: OverlayNotice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(notice.tint)
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(notice.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)

                    Text(notice.message)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let actionTitle = notice.actionTitle, let action = notice.action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(notice.tint)
            }
        }
        .padding(14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(notice.tint.opacity(0.32), lineWidth: 1)
        )
    }

    private func miniHint(_ text: String, compactUI: Bool) -> some View {
        Text(text)
            .font(.system(compactUI ? .caption2 : .footnote, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var placeholderPreview: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.84))

            Text(placeholderPreviewTitle)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)

            Text(captureService.captureHint)
                .font(.system(.subheadline, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    .black.opacity(0.80),
                    Color(red: 0.09, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var placeholderPreviewTitle: String {
        if captureService.environmentNotice != nil {
            return "Simulator Preview Placeholder"
        }

        if captureService.cameraPermission.isAuthorized {
            return "Preparing Camera"
        }

        return "Camera Preview Paused"
    }

    private var histogramOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Histogram")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                Spacer()
                Text("CLIP \(Int((captureService.histogramSnapshot.clippedRatio * 100).rounded()))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(captureService.histogramSnapshot.clippedRatio > 0.06 ? accentColor : .white.opacity(0.70))
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(captureService.histogramSnapshot.bins.enumerated()), id: \.offset) { entry in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(entry.element > 0.8 ? accentColor : Color.white.opacity(0.92))
                        .frame(width: 4, height: max(4, CGFloat(entry.element) * 34))
                }
            }
            .frame(height: 38, alignment: .bottom)
        }
        .padding(10)
        .frame(width: 160)
        .background(.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    private var levelOverlay: some View {
        let angle = captureService.levelAngleDegrees
        let clampedAngle = min(max(angle, -22), 22)
        let isLevel = abs(clampedAngle) < 1.2
        let tint = isLevel ? accentColor : Color.white.opacity(0.88)

        return VStack(spacing: 6) {
            ZStack {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: 112, height: 4)

                Capsule()
                    .fill(tint)
                    .frame(width: 92, height: 4)
                    .rotationEffect(.degrees(clampedAngle))

                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .shadow(color: tint.opacity(0.38), radius: 10, x: 0, y: 4)
            }

            Text(isLevel ? "Level" : "\(Int(clampedAngle.rounded()))°")
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.46), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }

    private var previewGridOverlay: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            Path { path in
                path.move(to: CGPoint(x: width / 3, y: 0))
                path.addLine(to: CGPoint(x: width / 3, y: height))

                path.move(to: CGPoint(x: width * 2 / 3, y: 0))
                path.addLine(to: CGPoint(x: width * 2 / 3, y: height))

                path.move(to: CGPoint(x: 0, y: height / 3))
                path.addLine(to: CGPoint(x: width, y: height / 3))

                path.move(to: CGPoint(x: 0, y: height * 2 / 3))
                path.addLine(to: CGPoint(x: width, y: height * 2 / 3))
            }
            .stroke(Color.white.opacity(0.32), lineWidth: 1)
        }
    }

    private func focusReticleOverlay(_ reticle: FocusReticle) -> some View {
        GeometryReader { proxy in
            let x = reticle.point.x * proxy.size.width
            let y = reticle.point.y * proxy.size.height

            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(reticle.isLocked ? accentColor : Color.white, lineWidth: 2)
                        .frame(width: 72, height: 72)

                    VStack {
                        Rectangle()
                            .fill(reticle.isLocked ? accentColor : Color.white)
                            .frame(width: 2, height: 14)
                        Spacer()
                        Rectangle()
                            .fill(reticle.isLocked ? accentColor : Color.white)
                            .frame(width: 2, height: 14)
                    }
                    .frame(height: 62)

                    HStack {
                        Rectangle()
                            .fill(reticle.isLocked ? accentColor : Color.white)
                            .frame(width: 14, height: 2)
                        Spacer()
                        Rectangle()
                            .fill(reticle.isLocked ? accentColor : Color.white)
                            .frame(width: 14, height: 2)
                    }
                    .frame(width: 62)
                }
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)

                if reticle.isLocked {
                    Text("AE/AF LOCK")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accentColor, in: Capsule())
                }
            }
            .position(x: x, y: y)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func togglePanel(_ panel: QuickPanel) {
        withAnimation(.easeInOut(duration: 0.22)) {
            activePanel = activePanel == panel ? nil : panel
        }
    }

    private func closeActivePanel() {
        guard activePanel != nil else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            activePanel = nil
        }
    }

    private func showFocusReticle(at point: CGPoint, locked: Bool) {
        let reticle = FocusReticle(point: point, isLocked: locked)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            focusReticle = reticle
        }

        let hideDelay = locked ? 1.8 : 1.1
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay) {
            guard focusReticle?.id == reticle.id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                focusReticle = nil
            }
        }
    }

    private func isCompactPhoneHeight(_ screenHeight: CGFloat) -> Bool {
        screenHeight <= 812
    }

    private func shouldShowStatusHUD(compactUI: Bool, isLandscape: Bool) -> Bool {
        guard compactUI else { return true }
        if isLandscape && activePanel != nil {
            return false
        }

        return activePanel != nil ||
            captureService.manualState.exposureMode != .auto ||
            captureService.selectedDriveMode != .single ||
            captureService.manualState.focusMode == .manual ||
            displayedWhiteBalanceMode == .manual ||
            captureService.isFocusExposureLocked
    }

    private var compactHUDLine: String {
        let focusOrWhiteBalance: String
        if captureService.isFocusExposureLocked || captureService.manualState.focusMode == .manual {
            focusOrWhiteBalance = focusHUDText
        } else if displayedWhiteBalanceMode == .manual {
            focusOrWhiteBalance = whiteBalanceHUDText
        } else {
            focusOrWhiteBalance = "\(captureService.selectedSaveFormat.rawValue) · \(shotHUDText)"
        }

        return "\(captureService.selectedLens.title) · \(exposureHUDText) · \(focusOrWhiteBalance)"
    }

    private func drawerHeight(for screenSize: CGSize, isLandscape: Bool) -> CGFloat {
        if isLandscape {
            return min(max(screenSize.height * 0.28, 112), 152)
        }

        if isCompactPhoneHeight(screenSize.height) {
            return min(max(screenSize.height * 0.16, 132), 176)
        }

        return min(max(screenSize.height * 0.19, 148), 220)
    }

    private func panelNote(for panel: QuickPanel) -> String? {
        switch panel {
        case .lens:
            return nil
        case .exposure:
            return captureService.exposureControlNote
        case .focus:
            return captureService.focusControlNote
        case .whiteBalance:
            return captureService.whiteBalanceControlNote
        case .more:
            return captureService.driveControlNote ?? (
                captureService.capabilities.supportsConstantColor
                    ? "Constant Color stays in More so the main camera screen stays simple."
                    : captureService.capabilities.constantColorUnavailableReason
            )
        }
    }

    private func drawerValueText(for panel: QuickPanel?) -> String? {
        guard let panel else { return nil }

        switch panel {
        case .lens:
            return captureService.selectedLens.title
        case .exposure:
            return captureService.manualState.exposureMode.title
        case .focus:
            return focusHUDText
        case .whiteBalance:
            return whiteBalanceHUDText
        case .more:
            return "\(captureService.selectedMode == .constantColor ? "Constant" : "Manual") · \(shotHUDText)"
        }
    }

    private var hudItems: [String] {
        [
            "\(captureService.selectedLens.title) \(captureService.selectedSaveFormat.rawValue) \(captureService.apertureReadout)",
            exposureHUDText,
            focusHUDText,
            "\(whiteBalanceHUDText) · \(shotHUDText)"
        ]
    }

    private var shotHUDText: String {
        if captureService.selectedDriveMode == .longExposure {
            switch captureService.selectedLongExposureMode {
            case .manual:
                return "Long \(captureService.longExposureReadout)"
            case .nightAuto:
                return "Night Auto"
            }
        }

        return captureService.selectedDriveMode.title
    }

    private var activeAssistSummary: String {
        var parts: [String] = []

        if captureService.previewAssistState.showGrid {
            parts.append("Grid")
        }

        if captureService.previewAssistState.showHistogram {
            parts.append("Hist")
        }

        if captureService.previewAssistState.showHighlightWarning {
            parts.append("Zebra")
        }

        if captureService.previewAssistState.showFocusPeaking {
            parts.append("Peak")
        }

        if captureService.previewAssistState.showLevel {
            parts.append("Level")
        }

        return parts.joined(separator: " · ")
    }

    private func activeAssistBadgeText(compactUI: Bool) -> String {
        if activeAssistShortcuts.count > 1 {
            return "Assist \(activeAssistShortcuts.count)"
        }

        if compactUI && activeAssistSummary.count > 8 {
            return "Assist"
        }

        return activeAssistSummary
    }

    private var activeAssistShortcuts: [AssistShortcut] {
        var shortcuts: [AssistShortcut] = []

        if captureService.previewAssistState.showGrid {
            shortcuts.append(AssistShortcut(id: "grid", title: "Grid", disable: {
                captureService.setGridEnabled(false)
            }))
        }

        if captureService.previewAssistState.showHistogram {
            shortcuts.append(AssistShortcut(id: "histogram", title: "Hist", disable: {
                captureService.setHistogramEnabled(false)
            }))
        }

        if captureService.previewAssistState.showHighlightWarning {
            shortcuts.append(AssistShortcut(id: "zebra", title: "Zebra", disable: {
                captureService.setHighlightWarningEnabled(false)
            }))
        }

        if captureService.previewAssistState.showFocusPeaking {
            shortcuts.append(AssistShortcut(id: "peaking", title: "Peak", disable: {
                captureService.setFocusPeakingEnabled(false)
            }))
        }

        if captureService.previewAssistState.showLevel {
            shortcuts.append(AssistShortcut(id: "level", title: "Level", disable: {
                captureService.setLevelEnabled(false)
            }))
        }

        return shortcuts
    }

    private var hasActiveAssistShortcuts: Bool {
        !activeAssistShortcuts.isEmpty
    }

    private var exposureHUDText: String {
        switch captureService.manualState.exposureMode {
        case .auto:
            return "Auto"
        case .ap:
            let bias = captureService.manualState.exposureBias
            return abs(bias) >= 0.05 ? "AP \(String(format: "%+.1fEV", bias))" : "AP"
        case .av:
            return "AV \(captureService.isoReadout)"
        case .tv:
            return "TV \(captureService.shutterReadout)"
        case .manual:
            return "M \(captureService.shutterReadout) \(captureService.isoReadout)"
        }
    }

    private var focusHUDText: String {
        if captureService.manualState.focusMode == .manual {
            return captureService.focusReadout
        }

        return captureService.isFocusExposureLocked ? "AE/AF Lock" : "AF Auto"
    }

    private var whiteBalanceHUDText: String {
        displayedWhiteBalanceMode == .manual ? captureService.whiteBalanceReadout : "AWB"
    }

    private var footerStatusText: String? {
        if captureService.isCaptureInProgress {
            return "Finishing capture…"
        }

        if captureService.selectedDriveMode == .longExposure &&
            captureService.cameraPermission.isAuthorized &&
            captureService.photoPermission.isAuthorized &&
            captureService.isSessionConfigured &&
            captureService.isSessionRunning {
            switch captureService.selectedLongExposureMode {
            case .manual:
                return "Long exposure at \(captureService.longExposureReadout). Hold still or use a tripod."
            case .nightAuto:
                let postureNote = captureService.selectedNightAutoPreset == .handheld
                    ? "Steady your hands before pressing the shutter."
                    : "Use a tripod or stable support."
                return "Night Auto \(captureService.selectedNightAutoPreset.title.lowercased()) is metering \(captureService.nightAutoPlanReadout). \(postureNote)"
            }
        }

        if captureService.cameraPermission.isAuthorized && captureService.photoPermission.isAuthorized && captureService.isSessionConfigured && captureService.isSessionRunning {
            return nil
        }

        return captureService.captureHint
    }

    private var overlayNotice: OverlayNotice? {
        if let permissionGuidance = captureService.permissionGuidance {
            return OverlayNotice(
                title: "Access Needed",
                message: permissionGuidance,
                tint: .red,
                actionTitle: captureService.shouldShowSettingsButton ? "Open Settings" : nil,
                action: captureService.shouldShowSettingsButton ? captureService.openSettings : nil
            )
        }

        if let banner = captureService.statusBanner {
            return OverlayNotice(
                title: bannerTitle(for: banner.kind),
                message: banner.message,
                tint: bannerColor(for: banner.kind)
            )
        }

        if let environmentNotice = captureService.environmentNotice {
            return OverlayNotice(
                title: "Simulator Limits",
                message: environmentNotice,
                tint: accentColor
            )
        }

        if let modeNotice = captureService.modeNotice {
            return OverlayNotice(
                title: "Mode Note",
                message: modeNotice,
                tint: accentColor
            )
        }

        if let driveModeNotice = captureService.driveModeNotice {
            return OverlayNotice(
                title: "Shot Note",
                message: driveModeNotice,
                tint: accentColor
            )
        }

        return nil
    }

    private var isPreviewControlDisabled: Bool {
        !captureService.cameraPermission.isAuthorized ||
        !captureService.isSessionConfigured ||
        captureService.isCaptureInProgress
    }

    private func isDriveModeDisabled(_ driveMode: CaptureDriveMode) -> Bool {
        switch driveMode {
        case .single:
            return false
        case .bracket:
            return !captureService.supportsBracketCapture
        case .longExposure:
            return !captureService.supportsLongExposure
        }
    }

    private var displayedWhiteBalanceMode: WhiteBalanceControlMode {
        captureService.selectedMode == .constantColor ? .auto : captureService.manualState.whiteBalanceMode
    }

    private var exposureBiasBinding: Binding<Double> {
        Binding(
            get: { captureService.manualState.exposureBias },
            set: { captureService.setExposureBias($0) }
        )
    }

    private var isoBinding: Binding<Double> {
        Binding(
            get: { captureService.manualState.manualISO },
            set: { captureService.setManualISO($0) }
        )
    }

    private var lensPositionBinding: Binding<Double> {
        Binding(
            get: { captureService.manualState.lensPosition },
            set: { captureService.setLensPosition($0) }
        )
    }

    private var whiteBalanceBinding: Binding<Double> {
        Binding(
            get: { captureService.manualState.whiteBalanceTemperature },
            set: { captureService.setWhiteBalanceTemperature($0) }
        )
    }

    private var shutterSliderBinding: Binding<Double> {
        Binding(
            get: { log(max(captureService.manualState.manualShutterSeconds, 1.0 / 8_000.0)) },
            set: { captureService.setManualShutterSeconds(exp($0)) }
        )
    }

    private var shutterLogRange: ClosedRange<Double> {
        let minSeconds = max(captureService.capabilities.minShutterSeconds, 1.0 / 8_000.0)
        let maxSeconds = max(captureService.capabilities.maxShutterSeconds, minSeconds)
        return log(minSeconds)...log(maxSeconds)
    }

    private var exposureBiasText: String {
        String(format: "%+.1f EV", captureService.manualState.exposureBias)
    }

    private func bannerTitle(for kind: StatusBanner.Kind) -> String {
        switch kind {
        case .info:
            return "Status"
        case .success:
            return "Saved"
        case .error:
            return "Issue"
        }
    }

    private func bannerColor(for kind: StatusBanner.Kind) -> Color {
        switch kind {
        case .info:
            return accentColor
        case .success:
            return .green
        case .error:
            return .red
        }
    }

    private func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }

        return "1/\(Int((1 / seconds).rounded()))"
    }
}
