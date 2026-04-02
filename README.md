# NoCorny Tracer 🚀

**NoCorny Tracer** is a modern macOS menu bar application designed for seamless screen and face-cam recording, integrated with AI-powered video naming (Gemini) and automated cloud sync (Dropbox).

---

## 🗺️ Documentation Map

This project uses a systematized documentation structure. Please refer to the guides below:

| Category | File | Description |
| :--- | :--- | :--- |
| **Getting Started** | [README.md](./README.md) | This master document. |
| **Releasing** | [PUBLISHING.md](./docs/PUBLISHING.md) | How to build, sign, and release new versions. |
| **Legal** | [PRIVACY_POLICY.md](./docs/PRIVACY_POLICY.md) | Privacy policy for users. |
| **Legal** | [TERMS_OF_SERVICE.md](./docs/TERMS_OF_SERVICE.md) | Terms of service for users. |
| **History** | [CHANGELOG.md](./CHANGELOG.md) | Log of all versions and changes. |

---

## 🛡️ Security & Secrets

To prevent exposing sensitive API keys and secrets (Dropbox, Gemini, etc.), we follow these rules:

1.  **Never commit `Secrets.swift`**: This file is explicitly ignored in `.gitignore`.
2.  **Use Templates**: New developers should copy `Sources/NoCornyTracer/Secrets.swift.template` to `Sources/NoCornyTracer/Secrets.swift` and fill in their own keys.
3.  **No Hardcoded Tokens**: Never put GitHub Tokens or API keys directly in script files or markdown documentation.
4.  **Local Testing**: Use a temporary Bundle Identifier for local testing to avoid conflicts with production installs.

---

## 🤖 For AI Agents (Mandatory Reading)

Before starting any task in this repository, you **MUST** read the following workflows to understand the established patterns:

1.  **Versioning**: [.agents/workflows/versioning.md](./.agents/workflows/versioning.md) - How to increment version numbers.
2.  **Releasing**: [.agents/workflows/github-release.md](./.agents/workflows/github-release.md) - How to deploy to GitHub.
3.  **Testing**: [.agents/workflows/testing.md](./.agents/workflows/testing.md) - How to run test builds with a custom Bundle ID.

> [!IMPORTANT]
> Always verify `.gitignore` before recommending any file creations to ensure secrets are not accidentally tracked.

---

## 🛠️ Tech Stack
- **Language**: Swift (SwiftUI)
- **Frameworks**: Sparkle (Auto-updates), SwiftyDropbox
- **AI**: Gemini Pro Vision (via Proxy)
- **Deployment**: Custom bash scripts (`release.sh`, `build_dmg.sh`)
