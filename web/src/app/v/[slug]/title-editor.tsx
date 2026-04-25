"use client";

import { useState } from "react";

type Props = {
  slug: string;
  initialTitle: string;
  isOwner: boolean;
  headingClass: string;
  onTitleChange: (title: string) => void;
};

export function TitleEditor({
  slug,
  initialTitle,
  isOwner,
  headingClass,
  onTitleChange,
}: Props) {
  const [title, setTitle] = useState(initialTitle);
  const [isEditing, setIsEditing] = useState(false);
  const [draft, setDraft] = useState(title);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    const trimmed = draft.trim();
    if (!trimmed || trimmed === title) {
      cancel();
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const res = await fetch(`/api/videos/${slug}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: trimmed }),
      });
      if (!res.ok) throw new Error("Failed to save title");
      setTitle(trimmed);
      onTitleChange(trimmed);
      setIsEditing(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed");
    } finally {
      setSaving(false);
    }
  }

  function cancel() {
    setDraft(title);
    setIsEditing(false);
    setError(null);
  }

  if (isEditing) {
    return (
      <div className="flex flex-col gap-2 min-w-0 w-full">
        <input
          className={`font-heading font-bold text-text-primary bg-transparent border-b-2 border-[color:var(--brand-purple)] outline-none w-full min-w-0 ${headingClass}`}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") save();
            if (e.key === "Escape") cancel();
          }}
          autoFocus
          disabled={saving}
        />
        {error && <div className="text-xs text-brand-red">{error}</div>}
        <div className="flex items-center gap-2">
          <button onClick={save} className="btn-gradient" disabled={saving}>
            {saving ? "Saving…" : "Save"}
          </button>
          <button onClick={cancel} className="btn-ghost" disabled={saving}>
            Cancel
          </button>
        </div>
      </div>
    );
  }

  if (!isOwner) {
    return (
      <h1 className={`font-heading font-bold text-text-primary ${headingClass}`}>
        {title}
      </h1>
    );
  }

  return (
    <div
      className="group inline-flex items-center gap-2 -mx-2 px-2 py-1 rounded-md transition-colors duration-[150ms] hover:bg-[var(--bg-card)] cursor-pointer"
      onClick={() => { setDraft(title); setIsEditing(true); }}
      title="Click to edit title"
    >
      <h1 className={`font-heading font-bold text-text-primary ${headingClass}`}>
        {title}
      </h1>
      <svg
        width="16"
        height="16"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden
        className="opacity-0 group-hover:opacity-100 max-md:opacity-100 transition-opacity duration-[150ms] text-text-tertiary flex-shrink-0"
      >
        <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" />
      </svg>
    </div>
  );
}
