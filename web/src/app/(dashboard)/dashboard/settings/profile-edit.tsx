"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { signOut } from "next-auth/react";

type Props = {
  initialName: string | null;
  initialImage: string | null;
  email: string;
  dropboxConnected: boolean;
};

export function ProfileEdit({ initialName, initialImage, email, dropboxConnected }: Props) {
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [name, setName] = useState(initialName ?? "");
  const [image, setImage] = useState(initialImage ?? "");
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function saveName() {
    setSaving(true);
    setError(null);
    try {
      const res = await fetch("/api/user/me", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
      });
      if (!res.ok) throw new Error(`Save failed (${res.status})`);
      setEditing(false);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  function cancelEdit() {
    setName(initialName ?? "");
    setEditing(false);
    setError(null);
  }

  async function uploadAvatar(file: File) {
    if (!dropboxConnected) {
      setError("Connect Dropbox first — avatars are stored in your Dropbox.");
      return;
    }
    if (!file.type.startsWith("image/")) {
      setError("Please drop an image file.");
      return;
    }
    setUploading(true);
    setError(null);
    try {
      const jpeg = await resizeImageToJpeg(file, 512, 0.85);
      const form = new FormData();
      form.append("file", jpeg, "avatar.jpg");
      const res = await fetch("/api/user/avatar", { method: "POST", body: form });
      if (!res.ok) {
        const msg = await res.json().catch(() => ({}));
        throw new Error(msg.error || `Upload failed (${res.status})`);
      }
      const data = await res.json();
      setImage(data.image || "");
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Upload failed");
    } finally {
      setUploading(false);
    }
  }

  const initial = (name || email)[0]?.toUpperCase() ?? "?";

  async function resizeImageToJpeg(file: File, maxSide: number, quality: number): Promise<File> {
    const dataUrl = await new Promise<string>((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(r.result as string);
      r.onerror = () => reject(r.error);
      r.readAsDataURL(file);
    });
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const i = new Image();
      i.onload = () => resolve(i);
      i.onerror = () => reject(new Error("Image decode failed"));
      i.src = dataUrl;
    });
    const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
    const w = Math.max(1, Math.round(img.width * scale));
    const h = Math.max(1, Math.round(img.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("Canvas 2D unavailable");
    ctx.drawImage(img, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, "image/jpeg", quality)
    );
    if (!blob) throw new Error("Image encode failed");
    return new File([blob], "avatar.jpg", { type: "image/jpeg" });
  }

  return (
    <div className="flex flex-col gap-5">
      {/* Avatar + identity */}
      <div
        onDragOver={(e) => {
          e.preventDefault();
          setDragging(true);
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragging(false);
          const file = e.dataTransfer.files?.[0];
          if (file) uploadAvatar(file);
        }}
        className={`flex flex-col sm:flex-row items-center sm:items-start gap-5 rounded-xl transition-colors ${
          dragging ? "ring-2 ring-brand bg-brand/5" : ""
        }`}
      >
        <button
          type="button"
          onClick={() => fileInputRef.current?.click()}
          className="relative w-20 h-20 shrink-0 rounded-full overflow-hidden group cursor-pointer focus:outline-none focus:ring-2 focus:ring-brand"
          title="Click or drop an image to change avatar"
        >
          {image ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={image} alt="" className="w-20 h-20 object-cover" />
          ) : (
            <div className="w-20 h-20 bg-brand flex items-center justify-center text-text-alt text-2xl font-bold">
              {initial}
            </div>
          )}
          <div className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 flex items-center justify-center text-white text-xs font-medium transition-opacity">
            {uploading ? "Uploading…" : "Change"}
          </div>
        </button>

        <div className="flex-1 min-w-0 text-center sm:text-left">
          <p className="font-semibold text-text-primary truncate">
            {name || "No name set"}
          </p>
          <p className="text-sm text-text-tertiary mb-1 truncate">{email}</p>
          <p className="text-xs text-text-tertiary">
            {dropboxConnected
              ? "Click avatar to change photo. Stored in Dropbox."
              : "Connect Dropbox below to upload an avatar."}
          </p>
        </div>

        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          className="hidden"
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) uploadAvatar(file);
            e.target.value = "";
          }}
        />
      </div>

      {/* Display name — read-only until "Edit name" clicked */}
      {editing ? (
        <div className="flex flex-col gap-3 pt-4 border-t border-[var(--card-border)]">
          <label className="flex flex-col gap-1">
            <span className="text-xs font-medium text-text-secondary">Display name</span>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Your name"
              className="px-3 py-2 rounded-lg border border-border bg-surface text-text-primary focus:outline-none focus:ring-2 focus:ring-brand"
              maxLength={120}
              autoFocus
            />
          </label>
          {error && <p className="text-sm text-red-500">{error}</p>}
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={saveName}
              disabled={saving}
              className="btn-gradient disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {saving ? "Saving…" : "Save name"}
            </button>
            <button
              type="button"
              onClick={cancelEdit}
              className="btn-ghost"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <div className="flex items-center justify-between gap-3 pt-4 border-t border-[var(--card-border)]">
          <div>
            <div className="text-xs font-medium text-text-secondary mb-0.5">Display name</div>
            <div className="text-sm text-text-primary">{name || <span className="text-text-tertiary">No name set</span>}</div>
          </div>
          <button
            type="button"
            onClick={() => setEditing(true)}
            className="btn-ghost text-sm shrink-0"
          >
            Edit name
          </button>
        </div>
      )}

      {/* Sign out */}
      <div className="pt-4 border-t border-[var(--card-border)]">
        <button
          type="button"
          onClick={() => signOut({ callbackUrl: "/" })}
          className="text-sm text-text-tertiary hover:text-brand-red transition-colors cursor-pointer"
        >
          Sign out
        </button>
      </div>
    </div>
  );
}
