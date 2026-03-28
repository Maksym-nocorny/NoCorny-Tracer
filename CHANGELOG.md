# Changelog

## [2.2.4] - 2026-03-28
### Fixed
- **Video Duration**: Corrected duration display by converting Dropbox API milliseconds to seconds (was always showing 00:00).
- **Delete Button**: Replaced `.alert()` with `.confirmationDialog()` so the delete confirmation no longer closes the app panel.
- **Recordings List Height**: Added a minimum height (150pt) so the list is compact with few recordings, and capped at 450pt maximum for many recordings.

## [2.2.3] - 2026-03-28
### Fixed
- **Window Scaling**: Corrected window height to be a reasonable 750px (2.5x of standard) instead of the previous 1250px.
- **Duration Parsing**: Improved numeric extraction from Dropbox metadata to ensure video length is correctly displayed.

## [2.2.2] - 2026-03-28
### Fixed
- **UI Jumping**: Stabilized recordings list layout to prevent items from shifting on hover.
- **Delete Bug**: Fixed an issue where the delete confirmation dialog would disappear if the mouse moved.
- **Duration Parsing**: Corrected video duration display (no longer shows 00:00).
- **Window Scaling**: Increased window height and list area to fit more recordings.
### Changed
- Renamed "Your Recordings" instead of "Recent Recordings".

## [2.2.1] - 2026-03-28
### Added
- **Robust Dropbox Uploads**: Refactored session uploads to stream from disk, drastically reducing memory usage for large files.
- **Automatic Retries**: Implemented 3x retry logic for all cloud operations to handle brief network interruptions.

## [2.2.0] - 2026-03-28
### Added
- **Video Thumbnails**: Recent recordings now show actual video thumbnails from Dropbox instead of placeholders.
- **Improved Metadata**: Added actual video duration and file size to the recordings list.
- **Cloud Management**: Added a "Delete" button (on hover) to remove recordings from Dropbox with confirmation.
- **Detailed Storage Info**: The Dropbox storage bar now shows used and allocated space in GB/MB.
### Changed
- **Upload Feedback**: The "upload complete" green cloud icon now automatically hides after 5 seconds.
- **Empty State**: Improved the layout of the empty recordings list.

## [2.1.1] - 2026-03-28
### Fixed
- **UI Layout**: Improved the spacing and alignment of the Recordings list and Dropbox Storage bar.
- **Storage Bar Design**: Added a more consistent design for the storage indicator with a dedicated icon and improved progress bar.

## [2.1.0] - 2026-03-28
### Added
- **Dropbox Synchronization**: The recordings list now pulls live data directly from your Dropbox `/NoCorny Tracer/` folder.
- **Dropbox Storage Status Bar**: A new status bar showing available space and approximate remaining recording minutes (at 1080p 30fps).
- **Manual Sync**: Added a manual sync button to force-refresh recordings from Dropbox.
### Changed
- **Folder Structure**: All recordings and subtitles are now stored in a dedicated `/NoCorny Tracer/` folder on Dropbox.
- **Removed History**: Removed the local recording history and "Clear History" button in favor of live cloud syncing.

## [2.0.1] - 2026-03-28
### Fixed
- Internal bug fixes and stability improvements.

## [1.6.0] - 2026-03-28
### Added
- **Permissions Window**: A new centralized window that checks for required permissions (Screen Recording, Camera, Microphone, Accessibility) on launch and provides easy "Grant" buttons.
- **Real-time Status Tracking**: The permissions window now updates in real-time as permissions are granted in System Settings.
- **Launch at Login & Auto-Update Toggles**: Integrated these settings directly into the Permissions window for easier setup.
- **Manual Permissions Check**: Added a "Permissions..." button in the General settings tab.

## [1.5.0] - 2026-03-27
### Changed
- **UI Consistency**: Reduced the Settings header height to 51pt to match the main screen for a more uniform visual experience.
- **Header Alignment**: Standardized the back button size and vertical padding across navigation transitions.

## [1.4.9] - 2026-03-26
### Changed
- **UI/UX Polish**: Standardized section padding across the app for a more consistent visual rhythm.
- **Improved Readability**: Increased footer font size to 11pt and improved the visibility of the empty recordings state.
- **Settings Alignment**: Corrected the indentation of recording settings rows for better alignment with icons.
- **Branding**: Shortened the launch-at-login toggle label for a cleaner settings interface.




## [1.4.8] - 2026-03-26
### Fixed
- **Tray Icon State**: Fixed a race condition where the tray icon would fail to update to the "active recording" state on the first try after a video format change. State mutations are now guaranteed to occur on the main thread for reliable UI updates.

## [1.4.7] - 2026-03-26
### Changed
- **UI Enhancements**: Increased the size of the custom in-app header icon and app title text for better visibility.
- **Header Clean-up**: Removed the green connected indicator dot from the menu bar UI for a cleaner top bar.
### Fixed
- **Settings Version**: The About section in settings now displays the correct live version dynamically.

## [1.4.6] - 2026-03-26
### Fixed
- **In-App Icon Visibility**: Re-added the white background to the custom in-app header icon to ensure the 'N' is readable in transparent areas on dark mode.

## [1.4.5] - 2026-03-26
### Fixed
- **Icon Visibility**: Swapped the light and dark tray icon logic so white icons correctly display on dark menu bars, and black icons display on light menu bars.

## [1.4.4] - 2026-03-26
### Added
- **Dynamic Tray Icons**: Menu bar icon now accurately reflects your chosen aesthetic depending on whether your macOS theme is light or dark, and whether you are actively recording.

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
