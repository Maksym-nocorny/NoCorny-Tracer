"use client";

import { useCallback, useState } from "react";
import { PlayerProvider } from "./player-context";
import { VideoPlayer, ShareActions } from "./video-player";
import { DescriptionEditor } from "./description-editor";
import { TitleEditor } from "./title-editor";
import { TranscriptPanel } from "./transcript-panel";
import { ProcessingWatcher, type StatusPayload } from "./processing-watcher";
import type { TranscriptSegment } from "@/lib/db/schema";

type Props = {
  slug: string;
  directUrl: string | null;
  processingStatus: string;
  initialTitle: string;
  initialDescription: string | null;
  initialTranscriptSegments: TranscriptSegment[] | null;
  initialTranscriptSrt: string | null;
  initialThumbnailUrl: string | null;
  transcriptLanguage: string | null;
  isOwner: boolean;
  authorDisplay: string;
  authorImage: string | null;
  ago: string;
  views: number;
};

export function VideoPageShell({
  slug,
  directUrl,
  processingStatus,
  initialTitle,
  initialDescription,
  initialTranscriptSegments,
  initialTranscriptSrt,
  initialThumbnailUrl,
  transcriptLanguage,
  isOwner,
  authorDisplay,
  authorImage,
  ago,
  views,
}: Props) {
  const [title, setTitle] = useState(initialTitle);
  const [description, setDescription] = useState<string | null>(initialDescription);
  const [transcriptSegments, setTranscriptSegments] = useState<TranscriptSegment[] | null>(initialTranscriptSegments);
  const [transcriptSrt, setTranscriptSrt] = useState<string | null>(initialTranscriptSrt);
  const [thumbnailUrl, setThumbnailUrl] = useState<string | null>(initialThumbnailUrl);
  const [isProcessing, setIsProcessing] = useState(processingStatus === "processing");

  const [isEditingTitle, setIsEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState(initialTitle);
  const [titleSaving, setTitleSaving] = useState(false);
  const [titleError, setTitleError] = useState<string | null>(null);

  const handleReady = useCallback((data: StatusPayload) => {
    setTitle(data.title);
    setDescription(data.description);
    setTranscriptSegments(data.transcriptSegments);
    setTranscriptSrt(data.transcriptSrt);
    setThumbnailUrl(data.thumbnailUrl);
    setIsProcessing(false);
  }, []);

  async function saveTitle() {
    const trimmed = titleDraft.trim();
    if (!trimmed || trimmed === title) { setIsEditingTitle(false); return; }
    setTitleSaving(true);
    setTitleError(null);
    try {
      const res = await fetch(`/api/videos/${slug}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title: trimmed }),
      });
      if (!res.ok) throw new Error("Failed to save title");
      setTitle(trimmed);
      setIsEditingTitle(false);
    } catch (err) {
      setTitleError(err instanceof Error ? err.message : "Failed");
    } finally {
      setTitleSaving(false);
    }
  }

  function cancelTitle() {
    setTitleDraft(title);
    setIsEditingTitle(false);
    setTitleError(null);
  }

  function startEditTitle() {
    setTitleDraft(title);
    setIsEditingTitle(true);
  }

  const captionsSrc = transcriptSegments?.length ? `/v/${slug}/captions.vtt` : null;
  const hasTranscript = !!(transcriptSegments?.length);

  const authorAvatar = authorImage ? (
    // eslint-disable-next-line @next/next/no-img-element
    <img src={authorImage} alt="" className="w-8 h-8 rounded-full" />
  ) : (
    <div className="w-8 h-8 rounded-full bg-brand text-text-alt flex items-center justify-center font-bold text-sm">
      {authorDisplay.slice(0, 1).toUpperCase()}
    </div>
  );

  const authorMeta = (
    <div className="flex items-center gap-1.5 text-xs text-text-tertiary flex-wrap">
      <span className="text-sm font-semibold text-text-primary">{authorDisplay}</span>
      <span>·</span>
      <span>{ago}</span>
      <span>·</span>
      <span>{views} view{views !== 1 ? "s" : ""}</span>
    </div>
  );

  return (
    <>
      {/* Mobile: title above the player */}
      <div className="md:hidden mb-3">
        <div className="flex items-start gap-3 flex-wrap">
          <TitleEditor
            title={title}
            isOwner={isOwner}
            headingClass="text-2xl"
            isEditing={isEditingTitle}
            draft={titleDraft}
            onDraftChange={setTitleDraft}
            onStartEdit={startEditTitle}
            onSave={saveTitle}
            onCancel={cancelTitle}
            saving={titleSaving}
          />
          {isProcessing && (
            <span className="text-xs px-2 py-0.5 rounded-full border border-[var(--card-border)] text-text-tertiary animate-pulse">
              Processing…
            </span>
          )}
        </div>
        {isOwner && isEditingTitle && (
          <div className="flex items-center gap-2 mt-2">
            {titleError && <span className="text-xs text-brand-red">{titleError}</span>}
            <button onClick={saveTitle} className="btn-gradient" disabled={titleSaving}>
              {titleSaving ? "Saving…" : "Save"}
            </button>
            <button onClick={cancelTitle} className="btn-ghost" disabled={titleSaving}>
              Cancel
            </button>
          </div>
        )}
      </div>

      <PlayerProvider>
        {/*
          Desktop layout: outer flex puts ShareActions top-right (original position),
          while the grid inside flex-1 ensures title aligns exactly with the video column.
        */}
        <div className="flex items-start gap-4">
          <div className="min-w-0 flex-1">
            <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_360px] gap-6">

              {/* Video column */}
              <div className="min-w-0">

                {/* Desktop title + author — same width as video */}
                <div className="hidden md:block mb-5">
                  <div className="flex items-start gap-3 flex-wrap">
                    <TitleEditor
                      title={title}
                      isOwner={isOwner}
                      headingClass="text-3xl"
                      isEditing={isEditingTitle}
                      draft={titleDraft}
                      onDraftChange={setTitleDraft}
                      onStartEdit={startEditTitle}
                      onSave={saveTitle}
                      onCancel={cancelTitle}
                      saving={titleSaving}
                    />
                    {isProcessing && (
                      <span className="text-xs px-2 py-0.5 rounded-full border border-[var(--card-border)] text-text-tertiary animate-pulse self-center">
                        Processing…
                      </span>
                    )}
                  </div>

                  <div className="flex items-center justify-between gap-4 mt-2">
                    <div className="flex items-center gap-3 min-w-0">
                      {authorAvatar}
                      {authorMeta}
                    </div>
                    {isOwner && isEditingTitle && (
                      <div className="flex items-center gap-2 flex-shrink-0">
                        {titleError && <span className="text-xs text-brand-red">{titleError}</span>}
                        <button onClick={saveTitle} className="btn-gradient" disabled={titleSaving}>
                          {titleSaving ? "Saving…" : "Save"}
                        </button>
                        <button onClick={cancelTitle} className="btn-ghost" disabled={titleSaving}>
                          Cancel
                        </button>
                      </div>
                    )}
                  </div>
                </div>

                {/* Video */}
                <div className="-mx-6 md:mx-0">
                  <div className="md:rounded-lg md:overflow-hidden">
                    <VideoPlayer
                      src={directUrl}
                      slug={slug}
                      title={title}
                      poster={thumbnailUrl}
                      captionsSrc={captionsSrc}
                    />
                  </div>
                </div>

                {/* Mobile: author + actions below the video */}
                <div className="md:hidden mt-4">
                  <div className="flex items-center gap-3 mb-4">
                    {authorAvatar}
                    {authorMeta}
                  </div>
                  <ShareActions src={directUrl} />
                </div>

                <DescriptionEditor
                  key={description ?? "__empty__"}
                  slug={slug}
                  initialDescription={description}
                  isOwner={isOwner}
                  hasTranscript={hasTranscript}
                />
              </div>

              {/* Transcript column */}
              <div className="min-w-0">
                <TranscriptPanel
                  key={transcriptSrt ?? "__empty__"}
                  segments={transcriptSegments ?? []}
                  srt={transcriptSrt}
                  language={transcriptLanguage}
                  slug={slug}
                />
              </div>
            </div>
          </div>

          {/* ShareActions: desktop only, top-right, original position */}
          <div className="hidden md:block flex-shrink-0">
            <ShareActions src={directUrl} />
          </div>
        </div>
      </PlayerProvider>

      <ProcessingWatcher
        slug={slug}
        initialStatus={processingStatus}
        onReady={handleReady}
      />
    </>
  );
}
