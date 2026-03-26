# Changelog

## [1.4.3] - 2026-03-26
### Fixed
- **Updater Stability**: Final fix for the Sparkle "Update Error" by unifying DMG filenames to a no-space format while preserving the "NoCorny Tracer" display name.

## [1.4.2] - 2026-03-26
### Fixed
- **Updater Failure**: Fixed an "Update Error" in Sparkle caused by unencoded spaces in the download URLs.

## [1.4.1] - 2026-03-26
### Added
- **Custom Branding**: Replaced the system recording icon in the app header with a new custom branded icon.

## [1.4.0] - 2026-03-26
### Changed
- **Branding**: Renamed the application from "NoCornyTracer" to "NoCorny Tracer" (added a space) for better readability across the OS.

## [1.3.9] - 2026-03-26
### Added
- **New Visual Identity**: Completely redesigned application and tray icons for a more modern, cohesive look.

### Fixed
- **UI Capture Glitch**: Added a 0.5s delay before recording starts to ensure the tray popover is fully hidden and not captured in the video.
- **Tray Icon Scaling**: Fixed an issue where the tray icon wasn't correctly applying from the asset catalog by hard-coding the resource bundle path.

## [1.3.4] - 2026-03-26

### Fixed
- **Fatal Error on Launch**: Resolved a critical issue where the app would crash when loaded from a `.app` bundle due to the resource bundle not being found. Fixed by implementing a robust custom bundle locator in `NoCornyTracerApp.swift` that correctly targets the `Contents/Resources` directory.

### Improved
- **App Packaging**: Updated build and signing process to be fully compatible with macOS security requirements (avoiding unsealed contents in the bundle root).

## [1.3.0] - 2026-03-04

### Added
- **Floating Camera**: Added support for a floating face cam while recording.
- **Improved UI**: New modern menu bar interface.
- **DMG Distribution**: Added automated build script for creating DMG installers.

## [1.2.1] - Earlier
- Initial releases and core recording functionality.
