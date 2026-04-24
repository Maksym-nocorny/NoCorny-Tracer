"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useMediaStore } from "@vidstack/react";
import type { TranscriptSegment } from "@/lib/db/schema";
import { usePlayerRef } from "./player-context";

type Props = {
  segments: TranscriptSegment[];
  srt: string | null;
  language: string | null;
  slug: string;
};

type Paragraph = {
  paraIdx: number;
  start: number;
  end: number;
  text: string;
  firstSegIdx: number;
  lastSegIdx: number;
};

function formatTime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${r.toString().padStart(2, "0")}`;
}

const PARA_GAP_S = 1.5;

function groupIntoParagraphs(segments: TranscriptSegment[]): Paragraph[] {
  if (!segments.length) return [];
  const paras: Paragraph[] = [];
  let batch: TranscriptSegment[] = [segments[0]];
  let firstIdx = 0;

  for (let i = 1; i < segments.length; i++) {
    const prev = segments[i - 1];
    const curr = segments[i];
    const gap = curr.start - prev.end;
    const sentenceEnd = /[.!?]$/.test(prev.text.trimEnd());

    if (gap > PARA_GAP_S || sentenceEnd) {
      paras.push({
        paraIdx: paras.length,
        start: batch[0].start,
        end: prev.end,
        text: batch.map((s) => s.text).join(" "),
        firstSegIdx: firstIdx,
        lastSegIdx: i - 1,
      });
      batch = [curr];
      firstIdx = i;
    } else {
      batch.push(curr);
    }
  }

  const last = segments[segments.length - 1];
  paras.push({
    paraIdx: paras.length,
    start: batch[0].start,
    end: last.end,
    text: batch.map((s) => s.text).join(" "),
    firstSegIdx: firstIdx,
    lastSegIdx: segments.length - 1,
  });

  return paras;
}

export function TranscriptPanel({ segments, srt, language, slug }: Props) {
  const [query, setQuery] = useState("");
  const [copied, setCopied] = useState(false);

  const playerRef = usePlayerRef();
  const { currentTime } = useMediaStore(playerRef);

  const rowsRef = useRef<Map<number, HTMLButtonElement | null>>(new Map());
  const listRef = useRef<HTMLDivElement | null>(null);

  const paragraphs = useMemo(() => groupIntoParagraphs(segments), [segments]);

  const activeParaIdx = useMemo(() => {
    if (!paragraphs.length) return -1;
    for (let i = paragraphs.length - 1; i >= 0; i--) {
      if (currentTime >= paragraphs[i].start) return i;
    }
    return -1;
  }, [paragraphs, currentTime]);

  const filtered = useMemo(() => {
    if (!query.trim()) return paragraphs;
    const q = query.toLowerCase();
    return paragraphs.filter((p) => p.text.toLowerCase().includes(q));
  }, [paragraphs, query]);

  useEffect(() => {
    if (activeParaIdx < 0 || query) return;
    const row = rowsRef.current.get(activeParaIdx);
    const list = listRef.current;
    if (!row || !list) return;
    const rowTop = row.offsetTop - list.offsetTop;
    const rowBottom = rowTop + row.offsetHeight;
    if (rowTop < list.scrollTop || rowBottom > list.scrollTop + list.clientHeight) {
      list.scrollTo({ top: rowTop - 48, behavior: "smooth" });
    }
  }, [activeParaIdx, query]);

  function seekTo(time: number) {
    const p = playerRef.current;
    if (!p) return;
    p.currentTime = time;
    if (p.paused) p.play().catch(() => {});
  }

  async function copyAll() {
    const text = paragraphs.map((p) => p.text).join("\n\n");
    await navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  const hasTranscript = segments.length > 0;

  return (
    <aside className="rounded-lg border border-[var(--card-border)] bg-bg-card overflow-hidden flex flex-col min-h-[480px] max-h-[calc(100vh-200px)]">
      <div className="flex items-center gap-2 px-4 py-3 border-b border-[var(--card-border)]">
        <h2 className="font-heading text-base font-bold text-text-primary">
          Transcript
        </h2>
        {language && (
          <span className="chip !py-0.5 !text-[11px] uppercase">{language}</span>
        )}
        <div className="flex-1" />
        {hasTranscript && (
          <>
            <button
              onClick={copyAll}
              className="text-xs text-text-secondary hover:text-text-primary transition-colors px-2 py-1 rounded-md"
              title="Copy full transcript"
            >
              {copied ? "Copied" : "Copy"}
            </button>
            {srt && (
              <a
                href={`data:text/plain;charset=utf-8,${encodeURIComponent(srt)}`}
                download={`transcript-${slug}.srt`}
                className="text-xs text-text-secondary hover:text-text-primary transition-colors px-2 py-1 rounded-md"
                title="Download SRT"
              >
                SRT
              </a>
            )}
          </>
        )}
      </div>

      {!hasTranscript ? (
        <div className="flex-1 p-6 flex items-center justify-center">
          <div className="text-center max-w-[240px]">
            <div className="text-3xl mb-3">📝</div>
            <div className="font-semibold text-text-primary mb-1">
              No transcript yet
            </div>
            <div className="text-xs text-text-tertiary leading-relaxed">
              Record a new video to get an auto-generated transcript with
              click-to-seek and synced highlights.
            </div>
          </div>
        </div>
      ) : (
        <>
          <div className="px-3 pt-3 pb-2">
            <div className="toolbar-input !py-1.5 !px-3">
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="text-text-tertiary shrink-0"
                aria-hidden
              >
                <circle cx="11" cy="11" r="7" />
                <path d="m21 21-4.3-4.3" />
              </svg>
              <input
                type="search"
                placeholder="Search transcript"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </div>
          </div>

          <div
            ref={listRef}
            className="flex-1 overflow-y-auto px-2 pb-2 transcript-scroll"
          >
            {filtered.length === 0 ? (
              <div className="text-xs text-text-tertiary px-2 py-6 text-center">
                No matches for "{query}"
              </div>
            ) : (
              filtered.map((para) => {
                const isActive = para.paraIdx === activeParaIdx && !query;
                return (
                  <button
                    key={para.paraIdx}
                    ref={(el) => {
                      rowsRef.current.set(para.paraIdx, el);
                    }}
                    onClick={() => seekTo(para.start)}
                    className={`group w-full text-left px-3 py-2.5 rounded-md transition-colors flex gap-3 items-start cursor-pointer ${
                      isActive
                        ? "bg-[color-mix(in_oklab,var(--brand-purple)_14%,transparent)]"
                        : "hover:bg-bg-secondary"
                    }`}
                  >
                    <span
                      className={`font-mono text-[11px] shrink-0 mt-0.5 tabular-nums ${
                        isActive
                          ? "text-[color:var(--brand-purple)] font-semibold"
                          : "text-text-tertiary group-hover:text-text-secondary"
                      }`}
                    >
                      {formatTime(para.start)}
                    </span>
                    <span
                      className={`text-sm leading-relaxed ${
                        isActive ? "text-text-primary" : "text-text-secondary"
                      }`}
                    >
                      {para.text}
                    </span>
                  </button>
                );
              })
            )}
          </div>
        </>
      )}
    </aside>
  );
}
