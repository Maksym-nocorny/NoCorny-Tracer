"use client";

import { useState } from "react";

export function TracerToken() {
  const [token, setToken] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [copied, setCopied] = useState(false);

  async function generate() {
    setLoading(true);
    setCopied(false);
    try {
      const res = await fetch("/api/tokens", { method: "POST" });
      if (!res.ok) throw new Error("Failed to generate token");
      const data = await res.json();
      setToken(data.token);
    } catch (e) {
      console.error(e);
      alert("Failed to generate token");
    } finally {
      setLoading(false);
    }
  }

  async function copy() {
    if (!token) return;
    await navigator.clipboard.writeText(token);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div>
      <p className="text-sm text-text-secondary mb-4">
        Generate a token to sign in to the NoCorny Tracer macOS app. Your
        recordings will automatically be registered here and get shareable
        links.
      </p>

      {!token ? (
        <button
          onClick={generate}
          disabled={loading}
          className="inline-flex px-4 py-2 rounded-md bg-gradient-to-r from-[var(--gradient-start)] to-[var(--gradient-end)] text-white text-sm font-semibold hover:brightness-110 transition-all disabled:opacity-50 cursor-pointer"
        >
          {loading ? "Generating…" : "Generate desktop app token"}
        </button>
      ) : (
        <div>
          <div className="flex items-center gap-2 mb-2">
            <div className="w-2 h-2 rounded-full bg-brand-green" />
            <span className="text-sm font-medium text-text-primary">
              Token generated — copy it now, it won't be shown again
            </span>
          </div>
          <div className="flex gap-2 items-stretch">
            <code className="flex-1 px-3 py-2 rounded-md bg-bg-secondary text-xs font-mono text-text-primary break-all">
              {token}
            </code>
            <button
              onClick={copy}
              className="px-4 py-2 rounded-md bg-bg-secondary text-sm font-medium text-text-primary hover:brightness-95 transition-all cursor-pointer whitespace-nowrap"
            >
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
          <p className="text-xs text-text-tertiary mt-3">
            Paste this into the Tracer Account section in the macOS app's
            Settings. Generating a new token invalidates the previous one.
          </p>
        </div>
      )}
    </div>
  );
}
