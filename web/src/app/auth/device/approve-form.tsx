"use client";

import { useState } from "react";

export function ApproveDeviceForm({
  state,
  redirectUrl,
}: {
  state: string;
  redirectUrl: string;
}) {
  const [status, setStatus] = useState<"idle" | "approving" | "done" | "error">(
    "idle"
  );
  const [error, setError] = useState<string | null>(null);

  async function approve() {
    setStatus("approving");
    setError(null);
    try {
      const res = await fetch("/api/auth/device/approve", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ state, redirect: redirectUrl }),
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || `HTTP ${res.status}`);
      }
      const { redirectUrl: callback } = await res.json();
      setStatus("done");
      window.location.href = callback;
    } catch (err) {
      setStatus("error");
      setError(err instanceof Error ? err.message : "Failed to authorize");
    }
  }

  function cancel() {
    const callback = new URL(redirectUrl);
    callback.searchParams.set("state", state);
    callback.searchParams.set("error", "user_cancelled");
    window.location.href = callback.toString();
  }

  if (status === "done") {
    return (
      <div className="text-center">
        <div className="text-4xl mb-3">✅</div>
        <p className="font-semibold text-text-primary mb-1">Signed in</p>
        <p className="text-text-secondary text-sm">
          Returning to the desktop app. You can close this window.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <button
        onClick={approve}
        disabled={status === "approving"}
        className="font-body font-semibold rounded-md py-3 px-4 text-text-alt transition-opacity disabled:opacity-60"
        style={{
          background:
            "linear-gradient(135deg, var(--gradient-start), var(--gradient-end))",
        }}
      >
        {status === "approving" ? "Authorizing…" : "Approve & sign in"}
      </button>
      <button
        onClick={cancel}
        disabled={status === "approving"}
        className="font-body rounded-md py-3 px-4 border border-[var(--card-border)] text-text-secondary hover:text-text-primary transition-colors"
      >
        Cancel
      </button>
      {error && (
        <div className="text-sm text-brand-red mt-1">{error}</div>
      )}
    </div>
  );
}
