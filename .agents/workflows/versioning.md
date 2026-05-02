---
description: Explains how to number versions of the NoCorny Tracer app
---
# Versioning Scheme

This workflow defines the rules for incrementing the version number of the NoCorny Tracer application. The version format is `MAJOR.MINOR.PATCH` (e.g., `1.10.13`).

### 1. PATCH (Third Number)
Increment the third number for **minor bug fixes** or **UI updates**.
- **Example:** `1.4.9` becomes `1.4.10`.
- **Note:** This number continues to increment beyond 9 (e.g., `.10`, `.11`, etc.).

### 2. MINOR (Second Number)
Increment the second number for **other updates** (new features, significant improvements, or non-trivial changes).
- **Example:** `1.10.13` becomes `1.11.0`.
- **Note:** When the second number increments, the third number (PATCH) **starts from zero**.

### 3. MAJOR (First Number)
The first number is changed **only when explicitly requested** by the user.
- **Example:** `1.11.0` becomes `2.0.0` (only upon request).

---
> [!TIP]
> Always check the current version in `package.json` or `Info.plist` before applying these rules.

### Important: Bundle ID & App Name Constraints
As of version 3.0.0+, the application must use the following strict identifiers:
- **Bundle ID**: `com.nocorny.tracer`
- **App Name**: `"NoCorny Tracer"` (with a space)
- **Warning**: Do not revert the Bundle ID to `.app` or change the filename formatting. Sparkle checks the exact Bundle ID match. If the identifier in the downloaded update does not perfectly match the running app, Sparkle will throw an `SUInvalidHostBundleIdentifierError` and refuse to install the update to protect against hijacking.

> [!CAUTION]
> **Strict Testing Rule:** If you want to make a build for tests, YOU STRICTLY HAVE to change the bundle identifier to a temporary new one only for tests to prevent conflict with the main installed application. Do NOT use `com.nocorny.tracer` for local testing.
