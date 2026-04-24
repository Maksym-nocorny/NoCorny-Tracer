"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

export function DropboxConnect({
  isConnected,
  lastSynced,
}: {
  isConnected: boolean;
  lastSynced: string | null;
}) {
  const router = useRouter();
  const [disconnecting, setDisconnecting] = useState(false);

  async function handleDisconnect() {
    setDisconnecting(true);
    await fetch("/api/dropbox/disconnect", { method: "DELETE" });
    router.refresh();
  }

  if (isConnected) {
    return (
      <div>
        <div className="flex items-center gap-2 mb-3">
          <div className="w-2 h-2 rounded-full bg-brand-green" />
          <span className="text-sm font-medium text-text-primary">
            Connected
          </span>
        </div>
        {lastSynced && (
          <p className="text-sm text-text-tertiary mb-4">
            Last synced:{" "}
            {new Date(lastSynced).toLocaleString()}
          </p>
        )}
        <div className="flex gap-3">
          <button
            onClick={() => fetch("/api/sync/dropbox", { method: "POST" })}
            className="px-4 py-2 rounded-md bg-bg-secondary text-sm font-medium text-text-primary hover:brightness-95 transition-all cursor-pointer"
          >
            Sync now
          </button>
          <button
            onClick={handleDisconnect}
            disabled={disconnecting}
            className="px-4 py-2 rounded-md text-sm font-medium text-brand-red hover:bg-bg-secondary transition-all cursor-pointer disabled:opacity-50"
          >
            {disconnecting ? "Disconnecting…" : "Disconnect"}
          </button>
        </div>
      </div>
    );
  }

  return (
    <div>
      <p className="text-sm text-text-secondary mb-4">
        Connect your Dropbox account to sync your screen recordings.
      </p>
      <a
        href="/api/auth/dropbox"
        className="inline-flex px-4 py-2 rounded-md bg-gradient-to-r from-[var(--gradient-start)] to-[var(--gradient-end)] text-white text-sm font-semibold hover:brightness-110 transition-all"
      >
        Connect Dropbox
      </a>
    </div>
  );
}
