"use client";

import { useState } from "react";

type Props = {
  slug: string;
  initialDescription: string | null;
  isOwner: boolean;
  hasTranscript: boolean;
};

export function DescriptionEditor({
  slug,
  initialDescription,
  isOwner,
  hasTranscript,
}: Props) {
  const [description, setDescription] = useState(initialDescription ?? "");
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(description);
  const [saving, setSaving] = useState(false);
  const [generating, setGenerating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    setSaving(true);
    setError(null);
    try {
      const res = await fetch(`/api/videos/${slug}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ description: draft.trim() || null }),
      });
      if (!res.ok) {
        throw new Error("Failed to save description");
      }
      setDescription(draft.trim());
      setEditing(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed");
    } finally {
      setSaving(false);
    }
  }

  function cancel() {
    setDraft(description);
    setEditing(false);
    setError(null);
  }

  async function generate() {
    setGenerating(true);
    setError(null);
    try {
      const res = await fetch(`/api/videos/${slug}/generate-description`, {
        method: "POST",
      });
      if (!res.ok) throw new Error("Failed to generate description");
      const data = (await res.json()) as { description: string };
      setDescription(data.description);
      setDraft(data.description);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed");
    } finally {
      setGenerating(false);
    }
  }

  if (editing) {
    return (
      <section className="mt-6">
        <div className="flex items-center justify-between mb-2">
          <h2 className="font-heading text-lg font-bold text-text-primary">
            Description
          </h2>
        </div>
        <textarea
          className="w-full min-h-[140px] p-3 rounded-md bg-bg-card border border-[var(--card-border)] text-text-primary outline-none focus:border-[color:var(--brand-purple)]"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="What is this video about?"
          autoFocus
        />
        {error && (
          <div className="text-xs text-brand-red mt-2">{error}</div>
        )}
        <div className="flex items-center gap-3 mt-3">
          <button
            onClick={save}
            className="btn-gradient"
            disabled={saving}
          >
            {saving ? "Saving…" : "Save"}
          </button>
          <button
            onClick={cancel}
            className="btn-ghost"
            disabled={saving}
          >
            Cancel
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="mt-6">
      <div className="flex items-center justify-between mb-2">
        <h2 className="font-heading text-lg font-bold text-text-primary">
          Description
        </h2>
        {isOwner && (
          <div className="flex items-center gap-3">
            {description && hasTranscript && (
              <button
                onClick={generate}
                disabled={generating}
                className="text-sm text-text-secondary hover:text-text-primary transition-colors cursor-pointer disabled:opacity-50"
              >
                {generating ? "Regenerating…" : "Regenerate"}
              </button>
            )}
            <button
              onClick={() => setEditing(true)}
              className="text-sm text-text-secondary hover:text-text-primary transition-colors cursor-pointer flex items-center gap-1.5"
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden
              >
                <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z" />
              </svg>
              Edit
            </button>
          </div>
        )}
      </div>
      {description ? (
        <p className="text-text-secondary whitespace-pre-wrap leading-relaxed">
          {description}
        </p>
      ) : isOwner ? (
        <div className="flex flex-wrap items-center gap-3">
          {hasTranscript && (
            <button
              onClick={generate}
              disabled={generating}
              className="btn-gradient"
            >
              {generating ? "Generating…" : "Generate from transcript"}
            </button>
          )}
          <button
            onClick={() => setEditing(true)}
            className="text-sm text-text-tertiary italic hover:text-text-secondary transition-colors cursor-pointer text-left"
          >
            {hasTranscript ? "or write one yourself…" : "Add a description…"}
          </button>
        </div>
      ) : (
        <p className="text-text-tertiary italic text-sm">No description yet.</p>
      )}
      {error && (
        <div className="text-xs text-brand-red mt-2">{error}</div>
      )}
    </section>
  );
}
