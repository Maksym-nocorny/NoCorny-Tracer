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
  const [description, setDescription] = useState<string | null>(
    initialDescription
  );
  const [transcriptSegments, setTranscriptSegments] = useState<
    TranscriptSegment[] | null
  >(initialTranscriptSegments);
  const [transcriptSrt, setTranscriptSrt] = useState<string | null>(
    initialTranscriptSrt
  );
  const [thumbnailUrl, setThumbnailUrl] = useState<string | null>(
    initialThumbnailUrl
  );
  const [isProcessing, setIsProcessing] = useState(
    processingStatus === "processing"
  );

  const handleReady = useCallback((data: StatusPayload) => {
    setTitle(data.title);
    setDescription(data.description);
    setTranscriptSegments(data.transcriptSegments);
    setTranscriptSrt(data.transcriptSrt);
    setThumbnailUrl(data.thumbnailUrl);
    setIsProcessing(false);
  }, []);

  const captionsSrc = transcriptSegments?.length
    ? `/v/${slug}/captions.vtt`
    : null;
  const hasTranscript = !!(transcriptSegments?.length);

  return (
    <>
      {/* Desktop: title + author row above the player */}
      <div className="hidden md:flex flex-row items-start justify-between gap-4 mb-5">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-3 flex-wrap">
            <TitleEditor
              slug={slug}
              initialTitle={title}
              isOwner={isOwner}
              headingClass="text-3xl"
              onTitleChange={setTitle}
            />
            {isProcessing && (
              <span className="text-xs px-2 py-0.5 rounded-full border border-[var(--card-border)] text-text-tertiary animate-pulse">
                Processing…
              </span>
            )}
          </div>
          <div className="flex items-center gap-3 mt-2">
            {authorImage ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={authorImage} alt="" className="w-8 h-8 rounded-full" />
            ) : (
              <div className="w-8 h-8 rounded-full bg-brand text-text-alt flex items-center justify-center font-bold text-sm">
                {authorDisplay.slice(0, 1).toUpperCase()}
              </div>
            )}
            <div className="flex items-center gap-1.5 text-xs text-text-tertiary flex-wrap">
              <span className="text-sm font-semibold text-text-primary">
                {authorDisplay}
              </span>
              <span>·</span>
              <span>{ago}</span>
              <span>·</span>
              <span>
                {views} view{views !== 1 ? "s" : ""}
              </span>
            </div>
          </div>
        </div>
        <ShareActions src={directUrl} />
      </div>

      {/* Mobile: title above the player */}
      <div className="md:hidden mb-3">
        <div className="flex items-center gap-3 flex-wrap">
          <TitleEditor
            slug={slug}
            initialTitle={title}
            isOwner={isOwner}
            headingClass="text-2xl"
            onTitleChange={setTitle}
          />
          {isProcessing && (
            <span className="text-xs px-2 py-0.5 rounded-full border border-[var(--card-border)] text-text-tertiary animate-pulse">
              Processing…
            </span>
          )}
        </div>
      </div>

      <PlayerProvider>
        <div className="grid grid-cols-1 lg:grid-cols-[minmax(0,1fr)_360px] gap-6">
          <div className="min-w-0">
            {/* Mobile: video is full-width edge-to-edge */}
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
                {authorImage ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img src={authorImage} alt="" className="w-8 h-8 rounded-full" />
                ) : (
                  <div className="w-8 h-8 rounded-full bg-brand text-text-alt flex items-center justify-center font-bold text-sm">
                    {authorDisplay.slice(0, 1).toUpperCase()}
                  </div>
                )}
                <div className="flex items-center gap-1.5 text-xs text-text-tertiary flex-wrap">
                  <span className="text-sm font-semibold text-text-primary">
                    {authorDisplay}
                  </span>
                  <span>·</span>
                  <span>{ago}</span>
                  <span>·</span>
                  <span>
                    {views} view{views !== 1 ? "s" : ""}
                  </span>
                </div>
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
      </PlayerProvider>

      <ProcessingWatcher
        slug={slug}
        initialStatus={processingStatus}
        onReady={handleReady}
      />
    </>
  );
}
