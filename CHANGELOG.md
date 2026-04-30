# Changelog

## [3.9.3] - 2026-04-30
### Fixed
- **"Dropbox Connected" sheet appeared on every app launch**: After 3.8.0 moved Dropbox connection management to the web, the macOS app discovered an existing connection by fetching a proxied token from Tracer at launch. `DropboxAuthManager` doesn't persist `isSignedIn` across launches, so the in-memory state was always `false` when `applyProxiedToken` ran — and the "new connection?" check (`!self.isSignedIn`) was therefore always true, firing the success sheet every time. The sheet trigger now lives in `AppState.syncDropboxFromTracer`, gated by a session flag that flips after the *first* sync completes — so launch-time syncs (which can fire concurrently from both the init Task and `didBecomeActive` and race each other) never surface the modal, while later heartbeat/foreground syncs still trigger it the moment the user connects Dropbox on the web mid-session.

## [3.9.2] - 2026-04-29
### Fixed
- **Subtitles sometimes contained only one short segment for a multi-minute recording**: Gemini occasionally returns one tiny SRT entry (e.g. "Я сейчас делаю сайт..." at 0:01) for a 2-minute video that has speech throughout — the model is non-deterministic and sometimes truncates despite the prompt's "8-15 entries" instruction. The combined naming pass now compares the SRT's last timestamp against the VAD-detected speech duration; if it covers <30% (or ends before 5s) and there were ≥10s of detected speech, the call is retried up to 3× before accepting the partial result. Genuinely silent recordings (NO_SPEECH) bypass the check so they don't loop.
- **Description generation surrendered on the first 503 from Gemini**: When `gemini-2.5-flash-lite` returned "model is currently experiencing high demand" (a routine transient condition), `generateDescriptionForVideo` failed permanently and the video stayed without a description until the user happened to trigger a PATCH that retried it. Web-side description generation now retries up to 4 times with exponential backoff (2s/4s/8s) on 429/5xx/UNAVAILABLE/RESOURCE_EXHAUSTED responses. The recorded `ai_events` row carries the actual attempt count so the admin dashboard reflects retry pressure.

## [3.9.1] - 2026-04-29
### Fixed
- **Recording duration and file size were missing for re-imported videos**: When the macOS app reconnected to Dropbox, the rebuild walked the app folder but didn't request `include_media_info`, so newly imported rows had `null` for both `duration` and `fileSize` — making the Recordings list show `00:00` and breaking the Total Recording Time tile in the admin dashboard. The folder walk and `dropboxGetMetadata` now request media info, and `importMissingFiles` writes the duration extracted by Dropbox into the row. The 40 affected rows in the production DB were backfilled directly from `media_info`.
- **Fresh recordings on macOS were missing `fileSize`**: `RecordingManager.stopRecording()` created the `Recording` struct without populating `fileSize`, so the first registration call sent `null` and only the eventual Dropbox metadata sync filled it in. Now we read the on-disk file size immediately after `finishWriting` finishes and attach it to the recording before processing starts.

## [3.9.0] - 2026-04-29
### Added
- **AI cost analytics on tracer.nocorny.com**: Every Gemini call now reports its token usage and latency back to the backend, where a new `ai_events` table stores per-event prompt tokens, output tokens, modality breakdown, and computed USD cost. The naming/transcription run on macOS aggregates usage across all retry attempts before sending it with the video update so retries are billed too.
- **Internal admin dashboard at `/admin`**: Email-whitelisted overview of total videos, total recording time, total storage, AI spend, cost-per-video, cost-per-minute, success rate, top users by AI cost, recent uploads, recent AI errors, and Dropbox quota utilization. Drill-down at `/admin/users/[id]` shows per-user video list and full AI-event history. Whitelist is configured via the `ADMIN_EMAILS` env on Vercel.
### Changed
- `GeminiProxyClient` now returns a `GeminiProxyResult` (text + usage + model + latency) instead of a raw string. `AINamingService.generateSubtitlesAndName` returns a `NamingResult` struct that includes accumulated usage across retries.

## [3.8.2] - 2026-04-28
### Fixed
- **Recordings cache survived an app restart after disconnecting Dropbox**: 3.8.1 cleaned the cache when the disconnect happened mid-session, but if you disconnected Dropbox on the web and then quit & relaunched the macOS app, the Recordings tab still showed the old library. Two fixes: (a) on launch the Dropbox-status check now runs sequentially before the library reload (was parallel), so a stale cache is wiped before the incremental `?since=` sync would otherwise paper over the missing rows; (b) the disconnect-detected cleanup now triggers whenever a local library cache exists (any persisted recordings, storage quota, or sync cursor), not only when the in-memory connection flag flips — that flag is always false at the moment of launch.

## [3.8.1] - 2026-04-28
### Fixed
- **Recordings list lingered after disconnecting Dropbox on the web**: When you disconnected Dropbox on `tracer.nocorny.com`, the macOS app correctly switched the footer to "Connect Dropbox on Web" but the Recordings tab kept showing the old library. The cache wasn't cleared because the app uses an incremental `?since=updated_at` sync — and the web disconnect hard-deletes those rows from the DB, so they never come back as `isDeleted: true` markers. The Dropbox-status sync now wipes the local library state (recordings, storage usage, sync cursor) the moment it observes a disconnect transition, and does a fresh full reload when a new Dropbox account is connected mid-session.

## [3.8.0] - 2026-04-28
### Changed
- **Dropbox is now managed entirely on tracer.nocorny.com**: The macOS app no longer runs its own OAuth flow or stores Dropbox tokens. "Connect Dropbox" opens the web settings, and the app obtains short-lived access tokens from the Tracer backend. Disconnecting on the web propagates to the app within ~60 seconds (or instantly when you bring the app to the front), so a single click in your browser fully revokes the macOS app's access — no more out-of-sync state between web and Mac.
- **Switching Dropbox accounts now actually switches**: The OAuth flow now passes `force_reapprove=true`, so clicking "Connect" always shows Dropbox's approval screen and lets you pick a different account. Previously an active dropbox.com session silently re-approved the same account, making it impossible to swap accounts without signing out of Dropbox in the browser first.
### Added
- **Library rebuilds when you switch Dropbox accounts**: When the OAuth callback detects a different `account_id`, the previous account's video records are wiped from the database, the sync cursor is reset, and any video files in the new account's `/Apps/NoCorny Tracer/` folder are imported as fresh entries. The Library on the website always reflects the currently connected Dropbox.
- **Metadata backup in your own Dropbox**: AI titles, descriptions, transcripts, and view counts are written to `/.tracer-metadata.json` inside your Dropbox app folder — debounced after every change and finalized on disconnect. If you reconnect the same account later, the rebuild reads the backup and restores all metadata for files that still exist. Backups carry the user ID and Dropbox account ID, so we never restore from another user's snapshot.
### Important
- The `db-<APP_KEY>://` URL scheme has been removed from `Info.plist` — the app no longer needs to receive Dropbox OAuth callbacks.

## [3.7.1] - 2026-04-28
### Added
- **Library auto-refreshes when you open Recordings or focus the app**: Previously you had to click the refresh button to see metadata changes (e.g. a title you renamed on `tracer.nocorny.com`). The Recordings tab now silently re-syncs with our DB whenever you switch to that tab AND whenever the app window gets focus — so jumping back from your browser after a rename on the website immediately reflects locally. The sync is incremental (only fetches rows whose `updated_at` changed since the last sync), so in steady state it's a single zero-row HTTP request.

## [3.7.0] - 2026-04-28
### Changed
- **Library now syncs from our own database, not Dropbox**: The Recordings tab used to rebuild itself on every refresh by walking the Dropbox API (list folder + list shared links + per-file metadata fallback) — three or more round-trips, slow and rate-limited. It now reads from `tracer.nocorny.com`, which is the same database that powers the website, so the app and the site can never disagree. Refresh is incremental: the server uses each video's `updated_at` as a cursor and the client only fetches rows that changed since the last sync, so a typical refresh returns zero rows and is effectively instant.
- **Storage usage reads from the database too**: "X GB used" is now `SUM(file_size)` across the user's videos in our DB (always exact, always live); the Dropbox plan size ("Y GB allocated") is fetched once when Dropbox is connected and cached in our DB. The app no longer calls Dropbox for quota at runtime.
- **Deleting a recording is now atomic across app, site, and Dropbox**: Deleting in the app (or on the site) calls a single backend endpoint that soft-deletes the row in our DB and removes the file from Dropbox in one step. Previously the app deleted only from Dropbox; the DB record was never removed, so the site kept showing the video until the Dropbox webhook fired. The deletion now propagates instantly everywhere.
### Important
- The Dropbox webhook is now a safety net only: it soft-deletes DB rows for files that disappeared from the Dropbox folder via the Dropbox web/desktop UI. It no longer creates new DB rows from arbitrary Dropbox files — every legitimate upload goes through the app, with proper transcript and AI-generated metadata.

## [3.6.5] - 2026-04-28
### Fixed
- **Non-English recordings getting English names despite foreign-language narration**: When narrating in Russian or Ukrainian over English code/UI screenshots, the AI-generated filename was defaulting to English instead of matching the spoken language. The combined-call prompt now explicitly states that narrated language ALWAYS determines the output language, and screenshots showing code or English interfaces are ignored for language detection. Added worked examples showing Russian narration with English code → Russian filename (not English).

## [3.6.4] - 2026-04-28
### Fixed
- **Cyrillic transcripts collapsed into one paragraph**: Gemini in JSON-mode sometimes returns SRT with single-newline separators between entries instead of the standard blank line, especially for Cyrillic content. Standard SRT parsers then treat the whole transcript as one block — the timestamps and entry numbers leak into the paragraph text on the video page. Both the macOS post-processor and the server-side `parseSrt` now normalize single `\n` before "`<number>\n<timestamp> -->`" sequences into the proper blank-line separator before parsing, so transcripts split into segments correctly regardless of whether Gemini included the blank line.

## [3.6.3] - 2026-04-28
### Fixed
- **Description silently missing when transcript contains rough language**: Gemini's default safety filters block summarization of transcripts that contain mat or other strong language, returning an empty response. The catch-block on the server then logged a vague "empty response" error and the description quietly stayed null. Both the macOS Gemini proxy client and the server-side `generateText` now pass `safetySettings` with `BLOCK_NONE` for all categories — we're summarizing the user's own recording, not generating new content, so safety filters are inappropriate. Server now also logs `finishReason` and `blockReason` from the Gemini response so future blocks are diagnosable.
- **Awkward filenames in non-English recordings**: Names like "RimWorld игра караван приближается к дому и требуется ремонт кондиционеры" (full sentence, grammar error in the last word). The combined-call prompt previously asked for "title case" (an English-only concept) and gave only English/translated examples, which led Gemini to generate a literal sentence in any language with English-style capitalization. Rewritten to demand a short noun-phrase topic header (4-8 words), explicit "sentence case for Slavic languages, title case only for English", and worked examples of both good output and the kind of broken output to avoid.

## [3.6.2] - 2026-04-28
### Added
- **Title and description match the recording's spoken language**: When you narrate a recording in Ukrainian, Russian, Spanish, or any other language, the AI-generated filename and the description on the video page are now produced in that same language. Silent recordings continue to use English. Implemented by adding explicit language-mirroring instructions to both the macOS combined-call prompt and the server-side description prompt.
### Changed
- **Voice processing status is now visible in the log**: Each capture session now writes a clear status line (`🎤 Audio: Voice processing → enabled=true, AGC=true, bypassed=false`) so you can confirm Apple's Voice Isolation + AGC + Echo Cancellation engaged for the session. AGC and bypass are also explicitly set (rather than relying on defaults) for resilience against future macOS changes.

## [3.6.1] - 2026-04-27
### Fixed
- **Transcript shown as one solid block + missing description**: In JSON-mode, Gemini occasionally collapses the entire transcript into a single SRT entry spanning the whole recording. The web's SRT parser then sees one segment, which displays as an unbroken paragraph and bypasses automatic description generation. The macOS app now (a) instructs Gemini explicitly to produce 1-2 sentence entries with blank-line separators and shows a worked example, (b) always re-parses and re-formats the SRT before uploading (no more identity passthrough), (c) auto-splits any entry that's > 15 s and > 80 chars into sentence-sized chunks with proportionally distributed timestamps, and (d) falls back to a regex-based recovery when the response has no real newlines. Result: the transcript panel shows proper paragraphs again and descriptions are generated automatically.

## [3.6.0] - 2026-04-27
### Changed
- **AI cost optimization (~36% per recording)**: The transcription + naming pipeline now runs as a single Gemini call instead of two sequential ones, screenshots are sent at 1024×1024 (was 1568×1568) which still keeps code and UI legible, and silences in the audio are trimmed locally before sending — only the speech segments go to Gemini. The original MP4 in Dropbox is unchanged; SRT timestamps are mapped back onto the original timeline so subtitles sync with the unmodified video.
### Added
- **Skip transcription on silent recordings**: When the captured audio is essentially mute (e.g. UI demo with no narration), transcription is skipped entirely. The recording still gets an AI-generated name from screenshots alone.
- **Speed-up audio for transcription (Phase B, opt-in)**: Optional 1.25× time-stretch (preserves voice pitch) before sending to Gemini. Disabled by default until validated on Ukrainian/Russian recordings; flip `enableSpeedUp` in `AINamingService` to enable.

## [3.5.14] - 2026-04-27
### Fixed
- **Long videos getting no transcript or description**: The audio export step previously used `AVAssetExportPresetAppleM4A` (~256 kbps), which pushed 10+ minute recordings over Gemini's 20 MB inline-data limit and silently aborted transcription. The MP4 in Dropbox stays untouched, but for transcription we now re-encode the audio to 32 kbps mono 16 kHz (the standard input format for speech-to-text models) via AVAssetReader/Writer. A 10-minute clip is now ~2.4 MB; even a 60-minute clip fits comfortably under the limit.
### Changed
- **Audio post-processing logs are visible**: Every step in `generateSubtitles` and `generateName` (audio extraction, file size, Gemini calls, retry attempts, NO_SPEECH detection) now writes through `LogManager.shared.log` so it shows up in the user-visible log instead of console-only `print` output.
- **Retries on every transient error**: The Gemini retry loop in both subtitle generation and AI naming now retries on ANY error (network glitch, 5xx, proxy timeout) instead of only quota errors. Up to 3 attempts with 5s/10s/20s exponential backoff.
- **Outer retry for subtitles**: If the inner 3-retry loop still returns nil, `processRecording` now waits 10 seconds and runs the whole subtitle pipeline a second time (fresh audio extraction + new Gemini call). Belt-and-suspenders robustness for transient backend hiccups.

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
