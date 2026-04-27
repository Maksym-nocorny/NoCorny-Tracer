# Changelog

## [3.5.13] - 2026-04-27
### Fixed
- **Audio capture robustness**: After the AVAudioEngine + Voice Processing refactor in 3.5.12, the very first recording on some machines could end up with a silent audio track (no transcript, no description). Added three safeguards: `engine.prepare()` is now called before `engine.start()` so the audio graph and voice processing initialize before buffers start flowing; if a tap-delivered buffer reports `hostTime == 0`, the PTS now falls back to `CMClockGetHostTimeClock()` to keep audio aligned with video; a 2-second health check logs loudly if no buffers were received or if all PTS were invalid, so any future regression is diagnosable from logs.

## [3.5.12] - 2026-04-26
### Changed
- **Background audio suppression**: Microphone capture now runs through Apple's Voice Processing (the same noise suppression block FaceTime and Zoom use), so background TV, music with lyrics, distant voices, and side conversations are heavily attenuated in the recorded audio. Voice quality of the primary speaker is preserved.
- **Smarter transcription prompt**: Gemini is now explicitly instructed to transcribe only the primary, foreground speaker. Background voices, song lyrics, and side conversations are skipped — if no clear primary speaker is present, transcription returns no speech.
- **AI naming robustness**: When generating a filename, stray phrases that don't fit the visual context (background TV dialogue, song lyrics) are now ignored in favor of what's actually shown on screen.

## [3.5.11] - 2026-04-26
### Changed
- **Smarter AI naming**: Frames sent to Gemini are now anchored to transcript paragraph starts (snap to nearest paragraph boundary within ±8s of each evenly spaced target), so each screenshot lands on a meaningful topic shift instead of mid-transition. For silent recordings or short clips, falls back to evenly spaced sampling. Frame count now scales with duration (3 to 10 frames; ~1 per 10s).
- **Higher-resolution screenshots**: AI naming now extracts frames at up to 1568px on the long side (was 800px) with JPEG quality 0.85 (was 0.6). Code, UI labels, and tabs are now legible to the model, which yields more specific and accurate filenames.
- **Near-duplicate frame removal**: Perceptual hash (dHash) drops visually identical frames before they're sent to Gemini, reducing API cost and noise on static-screen recordings.

## [3.5.10] - 2026-04-26
### Changed
- **Settings URL**: Updated the settings link from `/dashboard/settings` to `/settings` for cleaner URL structure. Added 308 redirect for backward compatibility with older app versions.

## [3.5.9] - 2026-04-25
### Changed
- **Dropbox managed via web only**: Removed "Sign Out" button for Dropbox in the app. When connected, a "Manage" button opens tracer.nocorny.com/dashboard/settings where the user can disconnect. When not connected, "Connect Dropbox" also opens the web settings. Connection status syncs automatically when opening the Settings tab.

## [3.5.8] - 2026-04-24
### Fixed
- **Connect Dropbox — silent re-sync**: When signed in to a Tracer account, clicking "Connect Dropbox" now first checks if Dropbox is already connected on the web. If it is, the app connects silently without opening the browser. The browser only opens when Dropbox is not yet connected on the web.

## [3.5.7] - 2026-04-24
### Fixed
- **Dropbox disconnect bidirectional sync**: "Sign Out" from Dropbox in the macOS app now immediately removes the connection from the backend — no browser redirect needed. Switching to Settings tab now also checks live connection status, so if the user disconnects on the web, the app reflects it automatically.

## [3.5.6] - 2026-04-24
### Fixed
- **Dropbox disconnect**: The "Sign Out" button in Settings now fully disconnects Dropbox from the app. Fixed a bug where `isProxied` flag was not cleared, causing the app to automatically reconnect on next launch if the web settings page wasn't explicitly used to complete the disconnection. Web settings page "Disconnect" button now works (was previously non-functional) and properly removes the Dropbox connection from the backend.

## [3.5.5] - 2026-04-24
### Fixed
- **Player controls**: Removed invalid nested layout objects from the Vidstack slot config that were breaking the player layout after the previous update.
- **Dropbox storage card**: The storage usage card in the Recordings tab now shows immediately on launch instead of disappearing until the first sync completes (values are now persisted to disk).
- **Transcript grouping**: Transcript segments are now grouped into logical paragraphs (by pause gaps > 1.5s or sentence-ending punctuation) instead of showing every 5-second SRT chunk as a separate line.
- **Recordings tab links**: Clicking a recording (play button, copy link, double-click) now correctly opens the Tracer share URL when available, instead of always using Dropbox.

## [3.5.4] - 2026-04-24
### Changed
- **Instant share link**: The browser now opens immediately after Dropbox upload completes — no longer waits for Gemini to generate subtitles and title (saves 3–6 minutes). The web page shows a "Processing…" badge on the title and updates dynamically (no page reload) when AI processing finishes.

## [3.5.3] - 2026-04-24
### Fixed
- **Auto-open Tracer page**: Fixed a race where the app tried to read `tracerURL` from state before the async write landed, so the browser silently didn't open. Now opens the Tracer page directly from the API response.

## [3.5.2] - 2026-04-24
### Changed
- **Share auto-open**: After a recording is uploaded, only the Tracer page opens automatically. The Dropbox folder no longer opens — Tracer is the canonical share surface.
- **Settings avatar**: The Tracer account avatar is now cached on disk (with ETag / Last-Modified revalidation, once per day). Opening Settings no longer re-downloads the image every time.

## [3.5.1] - 2026-04-24
### Added
- **Transcripts on the web**: The app now forwards auto-generated subtitles (SRT) when registering videos with Tracer. The web player at `tracer.nocorny.com/v/{slug}` shows a synced transcript panel, captions, search, and an AI-generated description.

## [3.5.0] - 2026-04-15
### Added
- **Tracer Account**: New "NoCorny Tracer Account" section in Settings (above Dropbox). Sign in by pasting an API token generated at tracer.nocorny.com/dashboard/settings.
- **Web share links**: After recording and uploading, the app now registers each video with the Tracer backend and gets a public shareable page at `tracer.nocorny.com/v/{slug}`. The copy-link button in the Recordings tab now copies this Tracer URL instead of the raw Dropbox link.
- **Auto-open**: The browser opens the Tracer page (not the Dropbox link) automatically after processing finishes.
- **Fallback**: If not signed into Tracer, behaviour is unchanged — Dropbox shared link is used as before.

## [3.4.12] - 2026-04-11
### Changed
- **Security**: Secrets are now XOR-obfuscated in the binary — no longer extractable via `strings`.
- **Security**: Dropbox tokens moved from UserDefaults (plaintext) to macOS Keychain (encrypted). Existing sessions migrate automatically.

## [3.4.11] - 2026-04-10
### Added
- **Settings**: Dropbox connection confirmation sheet shown after successful OAuth login with user account details.

## [3.4.10] - 2026-04-10
### Changed
- **Settings**: Resolution, Frame Rate, Microphone, and Camera controls are now disabled (locked) while a recording is in progress, with a "Locked during recording" label shown in each section header.
- **Settings**: Removed the "Save Location" row from the Recording section.

## [3.4.9] - 2026-04-10
### Changed
- **Timer**: Recording timer centered horizontally between the tab bar and top card.
- **Microphone Row**: Audio sensitivity bar constrained to a compact width (80pt) with equal left/right gaps, instead of stretching across the full card.

## [3.4.8] - 2026-04-10
### Changed
- **Recorder UI**: Recording timer moved between the tab bar and top card, always visible (shows `00:00` when idle, live time when recording).
- **Recording Controls**: Pause/Resume button added as a third button alongside Abort and Stop (order: Abort → Pause → Stop).
- **Microphone Row**: Audio sensitivity bar now appears inline between the "Microphone" label and its toggle during recording.
- **Footer**: Storage time remaining (`~N min left`) moved to the right corner of the footer, visible across all tabs.
- **Storage Bar**: Removed redundant time-remaining text from the Dropbox storage card in the Recordings tab.

## [3.4.7] - 2026-04-10
### Added
- **Menubar Timer**: Live recording timer appears next to the menubar icon during recording, stays frozen while paused.
- **Smart Click Behavior**: During recording/pause, left-click opens the quick-access menu and right-click opens the app window. Swaps back to normal when idle.
- **Instant Window Hide**: App window disappears instantly when recording starts (no minimize animation).
### Changed
- **Resume Delay**: Reduced pause-to-resume delay from 1s to 0.5s.
- **Menubar Timer Sync**: Increased menubar poll rate to 0.1s to match in-app timer, eliminating desync after pause/resume.

## [3.4.6] - 2026-04-10
### Added
- **Right-Click Menubar Menu**: Added full context menu to menubar icon with quick-access recording controls (Start/Stop, Pause, Abort), app navigation (Open app, Dropbox folder), update checking, and quit option.

## [3.4.5] - 2026-04-10
### Fixed
- **Settings Pickers Theme Bug**: Replaced system `.menu`-style SwiftUI Pickers with custom pure-SwiftUI dropdown components to fix issue where picker text became invisible when toggling theme while on Settings tab.
### Changed
- **Settings Button Styling**: Unified visual design of all buttons in Settings panel (Sign Out, Open, Permissions, Show Logs) to match custom dropdown buttons with purple text on light purple background.

## [3.4.4] - 2026-04-09
### Changed
- **Dropbox Storage Bar**: Moved Dropbox storage indicator from Recorder tab to Recordings tab, pinned at the bottom so recordings scroll freely above it while storage status remains visible.
### Fixed
- **Theme Toggle Icon**: Sun icon in light mode now properly visible with darker color and increased size (14→16px) for better visibility.
- **Dark Mode Text Contrast**: Improved contrast for links and text in dark mode by lightening purple colors (`brandPurple` and `lightPurple`), making nocorny.agency link, email, and Settings buttons clearly readable.
- **Start Recording Button**: Changed from gradient to solid color to ensure white text remains contrastful on dark background.

## [3.4.3] - 2026-04-08
### Fixed
- **0-duration Recordings**: Added fallback metadata fetch via Dropbox API for recordings where duration is missing. Calls `/2/files/get_metadata` with `include_media_info: true` to recover accurate durations.
- **Subtitle Uploads**: Removed SRT file uploads to Dropbox (subtitles are still generated internally for AI naming).

## [3.4.2] - 2026-04-08
### Fixed
- **Menu Bar Icon**: Menubar icon now only changes color with system theme, not app theme. Uses template image for normal state and system appearance detection for recording state, ensuring it always matches the menubar's actual appearance.

## [3.4.1] - 2026-04-08
### Fixed
- **Email Button**: Fixed email button in "Made with love" card that was opening blank browser tabs. Button now reliably copies email to clipboard and displays "Copied!" feedback without triggering system mailto handler.

## [3.4.0] - 2026-04-08
### Added
- **Dark Theme**: Added theme toggle dropdown in top-right corner (Light / System / Dark modes) with sun/half-circle/moon SF Symbol icons. System mode automatically follows macOS appearance.
- **Adaptive Colors**: All UI colors now intelligently adapt to light and dark modes — backgrounds, text, cards, buttons, and brand purple for optimal readability in both themes.

## [3.3.5] - 2026-04-04
### Changed
- **Pointer Cursor**: All interactive buttons, links, and tabs now show pointing hand cursor on hover.
- **Input Device Pickers**: Mic and camera dropdowns now have consistent width (`minWidth: 160`).
- **Card Alignment**: Dropbox, General, and About cards now use left-aligned indented layout matching Recording and Input Devices cards.
- **Menu Bar Icons**: Swapped light/dark theme icon assignment to match correct appearance.
- **Recordings Card**: Recordings tab now wrapped in card design with consistent styling.
- **App Width**: Reduced window width from 420px to 340px (compact layout).
- **Recordings List**: Shows all recordings (removed 10-item limit), added bottom fade gradient to indicate scrollable content.

## [3.3.4] - 2026-04-04
### Changed
- **Settings Tab**: Settings is now a tab (Recorder / Recordings / Settings) instead of a toolbar gear button.
- **Typography**: Increased font sizes (+1pt globally) and default body weight to medium for better readability.
- **Menu Bar Icon**: Restored original 4-state icon behavior (light/dark theme × normal/recording state) using PNG resources.
- **Camera Default**: Added "Default Camera" option in Input Devices picker.

## [3.3.3] - 2026-04-04
### Changed
- **Tabs**: Added "Recorder" and "Recordings" tabs in header for cleaner navigation.
- **Input Devices**: Moved microphone and camera device pickers to Settings; main screen shows only toggles.
- **Card Contrast**: Darkened card background and added subtle border for better visual distinction.
- **Menu Bar Icon**: Restored status bar icon that shows recording state (red tint) and activates app window on click.

### Fixed
- **About Text**: Improved text contrast in Settings About section.
- **General Section**: Fixed General settings card not spanning full width.

## [3.3.2] - 2026-04-04
### Fixed
- **Font Loading**: Fixed custom font registration (Mulish, PT Sans) by searching multiple bundle paths and subdirectories, with diagnostic logging for troubleshooting.

## [3.3.1] - 2026-04-04
### Fixed
- **Window Layout**: Removed redundant in-content header (title bar already shows app name). Settings gear moved to native macOS toolbar.

## [3.3.0] - 2026-04-04
### Changed
- **Windowed App**: Converted from menu bar app to standalone windowed app with dock icon
- **Card-Based Layout**: Sections are now presented as cards with rounded corners and shadows on a white background
- **Design System**: Applied NoCorny Agency brand design — purple gradient primary buttons, Mulish body font, PT Sans headings, brand colors throughout (red #f9423a, green #00c040, purple #3e0693)
### Removed
- Menu bar icon and popover — the app now opens as a regular window

## [3.2.0] - 2026-04-04
### Important
- **BREAKING CHANGE**: The application's bundle identifier has changed to `com.nocorny.tracer`. Previous versions will no longer auto-update to this version. You MUST download a fresh copy.

## [3.1.3] - 2026-03-31
### Improved
- **Network Reliability**: Implemented staggered loading for thumbnails to prevent "network storm" connection drops at application launch.
- **Log Clarity**: Updated retry logic to use specific task names (e.g., "Thumbnail", "Shared Link") instead of generic "Upload" messages for better troubleshooting.

## [3.1.2] - 2026-03-31
### Added
- **Recording Start Log**: Added a specific "🔴 Recording Actually Started" log entry to clearly mark the beginning of video capture in the timeline.
### Improved
- **Modernized LogManager**: Implemented thread-safe background logging, size-based log rotation (2MB limit), and a diagnostic system header (OS version, hardware model).
- **Privacy Filtering**: Automated masking of local home directory paths in log files for safer sharing.
- **Retry Clarification**: Updated the retry log message to "🔄 Retry: Retrying previous upload" to distinguish it from the failure of current actions.

## [3.1.1] - 2026-03-31
### Added
- **Diagnostic Logging**: Persistent application logs are now saved to `~/Library/Application Support/NoCornyTracer/Logs/app.log` for background troubleshooting.
- **Show Logs Button**: Added a dedicated button in Settings > General to quickly access the app logs folder.
### Improved
- **Error Visibility**: Failed uploads now display the specific error message from Dropbox (e.g., "Insufficient space") in the recording row tooltip.
- **Task Robustness**: Refactored the background processing pipeline to reliably capture and persist upload errors and avoid race conditions.

## [3.1.0] - 2026-03-31
### Added
- **Gemini 2.5 Flash-Lite**: Migrated to the latest stable model for significantly faster and more efficient AI-powered video naming and transcription.
- **Privacy Focus**: Configured the Gemini API to bypass Google's "product improvement" data collection, ensuring that recordings and transcripts remain private (requires Paid tier).

## [3.0.5] - 2026-03-30
### Fixed
- **Timer & Duration**: Fixed inaccurate timer logic and large duration gaps in video files when using pause/resume.
- **PTS Re-stamping**: Implemented re-stamping for video and audio buffers to ensure the output file timeline perfectly matches the active recording time.

## [3.0.4] - 2026-03-30
### Fixed
- **Recording Sounds**: Fixed an issue where startup and resume sounds were captured in the recording. The app now plays the sound first, waits 1.0s for it to finish and the UI to hide, and only then starts the recording engine.

## [3.0.3] - 2026-03-30
### Fixed
- **Sound Notifications**: Fixed an issue where the resume sound was occasionally missing. Toggling pause/resume now uses the `Tink` sound for more reliable and immediate feedback.

## [3.0.2] - 2026-03-30
### Added
- **Sound Notifications**: Added curated macOS system sounds to provide audible feedback when a recording starts, stops, pauses, or is aborted. This helps confirm app actions and bridges the delay before capture begins.

## [3.0.0] - 2026-03-30
### Important
- **BREAKING CHANGE**: The application's bundle identifier has changed to `com.nocornytracer.mac.v3` to fix a local testing macOS conflict workflow. Previous versions will no longer autoupdate to this version. You MUST download a fresh copy. Old releases have been marked as OUTDATED.

## [2.4.1] - 2026-03-30
### Changed
- **App Name**: Returned the app name back to "NoCorny Tracer" (with a space) while preserving the new `com.nocornytracer.mac` bundle identifier.
## [2.4.0] - 2026-03-30
### Important
- **BREAKING CHANGE**: The application's bundle identifier has changed to fix a macOS menu bar bug. **You MUST delete the old `NoCorny Tracer.app` from your Applications folder before installing this update.** Your previous settings and Dropbox login will also be reset and you will need to log in again.
### Fixed
- **Menu Bar Icon**: Fixed a system-level bug where macOS would permanently hide the menu bar icon after multiple reinstalls.
- **Silent Exit**: Fixed an issue where the application would silently exit if macOS removed the icon due to a full menu bar. The app will now remain running in the background.

## [2.3.0] - 2026-03-29
### Added
- **Legal Compliance**: Added mandatory Privacy Policy and Terms of Service links to the Settings view for Dropbox production approval.
- **Dropbox Disclaimer**: Added a user-facing notice clarifying that the application is not endorsed by Dropbox, Inc.
### Fixed
- **Dropbox Storage**: Switched to using the Dropbox App Folder root path as the default storage location, ensuring reliable file sync in production App Folder mode.
- **Branding**: Updated status bar and connection icons to use standard `cloud` iconography for consistent Dropbox branding.

## [2.2.9] - 2026-03-29
### Fixed
- **Permissions Window**: Fixed an issue where the permission window would flash or appear incorrectly on every app launch even if all required permissions were already granted.

## [2.2.8] - 2026-03-29
### Fixed
- **Dropbox Login**: Implemented a global App Delegate to guarantee the Dropbox login process completes successfully regardless of the menu bar state.

## [2.2.7] - 2026-03-29
### Fixed
- **Dropbox Login**: Fixed an issue where the app would open but not complete the Dropbox login process if the permissions menu was closed during the browser redirect (SwiftUI `onOpenURL` bug).

## [2.2.6] - 2026-03-28
### Changed
- **UI Tweaks**: Removed the confusing video length metadata entirely from the recordings list.
- **Window Width**: Increased the main app window width from 340pt to 380pt to give UI elements more breathing room.
- **Button Layout**: Locked the "Delete" and "Cancel" inline buttons to a fixed size so text no longer splits across multiple lines (e.g. "Delet e").

## [2.2.5] - 2026-03-28
### Fixed
- **Settings View Height**: Removed fixed scrollable constraints, allowing the settings menu to size itself correctly to its content.
- **Delete Button**: Replaced macOS alert dialog with inline buttons to fix click detection and MenuBarExtra focus loss issues.
- **Video Duration**: Inherited original local recording duration while Dropbox backend processes video metadata to prevent temporary `00:00` durations.

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
