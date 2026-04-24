"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";

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
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSaving(false);
    }
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
      // Resize & re-encode as JPEG client-side. Avoids Vercel's ~4.5 MB body
      // limit on large PNG/HEIC uploads and keeps Dropbox storage tidy.
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
  const nameDirty = name !== (initialName ?? "");

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
      {/* Avatar drop zone + name */}
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
        className={`flex items-center gap-4 rounded-xl border-2 border-dashed p-3 transition-colors ${
          dragging
            ? "border-brand bg-brand/10"
            : "border-transparent hover:border-border"
        }`}
      >
        <button
          type="button"
          onClick={() => fileInputRef.current?.click()}
          className="relative w-16 h-16 shrink-0 rounded-full overflow-hidden group cursor-pointer focus:outline-none focus:ring-2 focus:ring-brand"
          title="Click or drop an image to change avatar"
        >
          {image ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={image} alt="" className="w-16 h-16 object-cover" />
          ) : (
            <div className="w-16 h-16 bg-brand flex items-center justify-center text-text-alt text-2xl font-bold">
              {initial}
            </div>
          )}
          <div className="absolute inset-0 bg-black/50 opacity-0 group-hover:opacity-100 flex items-center justify-center text-white text-xs font-medium transition-opacity">
            {uploading ? "Uploading…" : "Change"}
          </div>
        </button>

        <div className="flex-1 min-w-0">
          <p className="text-sm text-text-tertiary mb-0.5">{email}</p>
          <p className="text-xs text-text-tertiary">
            {dropboxConnected
              ? "Drag & drop an image or click the avatar to upload. Stored in your Dropbox."
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

      <label className="flex flex-col gap-1">
        <span className="text-xs font-medium text-text-secondary">Display name</span>
        <input
          type="text"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Your name"
          className="px-3 py-2 rounded-lg border border-border bg-surface text-text-primary focus:outline-none focus:ring-2 focus:ring-brand"
          maxLength={120}
        />
      </label>

      {error && <p className="text-sm text-red-500">{error}</p>}

      <div>
        <button
          type="button"
          onClick={saveName}
          disabled={saving || !nameDirty}
          className="btn-gradient disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {saving ? "Saving…" : "Save name"}
        </button>
      </div>
    </div>
  );
}
