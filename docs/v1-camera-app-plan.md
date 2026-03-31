# V1 Personal iPhone Camera App

## Summary
- Build a native iPhone app in SwiftUI with AVFoundation that matches the workflow of paid pro-camera apps in a narrow way: fast preview, intentional capture modes, and cleaner output.
- V1 has two modes: `RAW` and `Clean Photo`. `RAW` captures Bayer RAW/DNG when the current device supports it and saves only the DNG to Photos. `Clean Photo` captures a rendered HEIC/JPEG with Apple-managed extras reduced as much as AVFoundation allows and saves only that rendered asset.
- Keep the first milestone small: rear main camera only, direct install from Xcode first, and TestFlight only after Apple Developer Program enrollment.
- Inference: this is a reasonable solo project. A solid first build is likely a small-to-medium effort; the scope jumps quickly if you add manual controls, multiple lenses, or parity with full paid apps.

## Key Changes
- App shell: one SwiftUI camera screen with live preview, mode switch, shutter button, permission states, capture-progress/error messaging, and save confirmation.
- Camera pipeline: `AVCaptureSession` plus `AVCapturePhotoOutput` with runtime capability detection. If RAW DNG is unsupported on the active device/format, disable `RAW` mode with an explicit message instead of falling back silently.
- `Clean Photo` behavior: prefer HEIC and fall back to JPEG, choose low-latency/minimal-extra-processing settings, and disable optional distortion correction, red-eye reduction, dual-camera fusion, still-image stabilization, depth/semantic outputs, Live Photo, and flash by default where supported.
- Storage flow: request Camera and Photos Add Only permissions, write directly to the Photos library, and keep the returned local identifier so the UI can confirm success.
- Internal interfaces:
  - `CaptureMode`: `.raw`, `.cleanPhoto`
  - `CaptureCapabilities`: runtime flags such as `supportsRawDng`, `supportsHeic`, and current camera/device details
  - `CaptureService`: owns session lifecycle, mode switching, capture requests, and photo-library saves
  - `CaptureResult`: mode, file type, library identifier, and UI/error metadata
- Explicitly out of scope for v1: manual focus/exposure/white balance, lens switching, RAW+processed paired saves, histogram/zebra, editing, filters, video, ProRAW, and Constant Color.

## Test Plan
- Verify camera and Photos permission flows, including denied and later-enabled states.
- On a RAW-capable device, `RAW` mode saves a DNG to Photos and does not create a rendered companion image.
- On a device or format without RAW support, `RAW` mode is unavailable and the UI explains why without crashing.
- `Clean Photo` mode saves a single HEIC/JPEG asset and does not produce Live Photo, depth, or RAW sidecars.
- Validate repeated captures, background/foreground transitions, save failures, and low-storage behavior.
- Inspect saved assets to confirm expected file type and one-asset-per-shot behavior.

## Assumptions
- Minimum deployment target: iOS 17.0.
- Initial hardware target: your current iPhone only, using the rear main camera.
- Direct Xcode install is the first delivery path; internal TestFlight comes later once you enroll in the Apple Developer Program.
- If your current phone does not support Bayer RAW in the way you want, phase 2 can add ProRAW as a separate mode rather than changing the v1 goal.

## References
- [Capturing photos in RAW and Apple ProRAW formats](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats)
- [AVCapturePhotoCaptureDelegate](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate)
- [Choosing a Membership](https://developer.apple.com/support/compare-memberships/)
- [Keep colors consistent across captures (WWDC24)](https://developer.apple.com/videos/play/wwdc2024/10162/)
