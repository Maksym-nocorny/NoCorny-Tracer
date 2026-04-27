"use client";

import { useEffect, useRef, useState } from "react";
import "@vidstack/react/player/styles/default/theme.css";
import "@vidstack/react/player/styles/default/layouts/video.css";
import {
  MediaPlayer,
  MediaProvider,
  Poster,
  Track,
  useMediaStore,
} from "@vidstack/react";
import {
  DefaultVideoLayout,
  defaultLayoutIcons,
} from "@vidstack/react/player/layouts/default";
import { usePlayerRef } from "./player-context";

const PLAYBACK_RATES = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

function formatRate(rate: number): string {
  if (Number.isInteger(rate)) return `${rate}×`;
  return `${rate}×`;
}

function SpeedIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M12 3a9 9 0 0 1 9 9" />
      <path d="M3 12a9 9 0 0 1 9-9" />
      <path d="M12 12l4-2" />
      <circle cx="12" cy="12" r="1.25" fill="currentColor" />
      <path d="M4.5 18.5A9 9 0 0 0 12 21a9 9 0 0 0 7.5-2.5" />
    </svg>
  );
}

function SpeedMenu() {
  const playerRef = usePlayerRef();
  const { playbackRate } = useMediaStore(playerRef);
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    function handle(e: MouseEvent) {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", handle);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", handle);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  function setRate(rate: number) {
    const p = playerRef.current;
    if (p) p.playbackRate = rate;
    setOpen(false);
  }

  return (
    <div ref={rootRef} className="speed-menu">
      <button type="button" aria-label={`Playback speed: ${formatRate(playbackRate)}`} aria-expanded={open} title="Playback speed" onClick={() => setOpen((o) => !o)} className="speed-menu__trigger vds-button">
        <SpeedIcon />
        <span className="speed-menu__label">{formatRate(playbackRate)}</span>
      </button>
      {open && (
        <div role="menu" className="speed-menu__popover">
          <div className="speed-menu__header">Playback speed</div>
          {PLAYBACK_RATES.map((rate) => {
            const active = Math.abs(rate - playbackRate) < 0.001;
            return (
              <button key={rate} role="menuitemradio" aria-checked={active} onClick={() => setRate(rate)} className={`speed-menu__item${active ? " is-active" : ""}`}>
                <span>{formatRate(rate)}</span>
                {active && (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                    <polyline points="20 6 9 17 4 12" />
                  </svg>
                )}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

function SeekBack5() {
  const playerRef = usePlayerRef();
  function seek() {
    const p = playerRef.current;
    if (p) p.currentTime = Math.max(0, p.currentTime - 5);
  }
  return (
    <button type="button" className="vds-button" title="Seek backward 5s" aria-label="Seek backward 5 seconds" onClick={seek}>
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
        <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
        <path d="M3 3v5h5" />
        <text x="12" y="16" textAnchor="middle" fontSize="7.5" fontWeight="700" fill="currentColor" stroke="none" fontFamily="system-ui">5</text>
      </svg>
    </button>
  );
}

function SeekForward5() {
  const playerRef = usePlayerRef();
  function seek() {
    const p = playerRef.current;
    if (p) p.currentTime = Math.min(p.duration || Infinity, p.currentTime + 5);
  }
  return (
    <button type="button" className="vds-button" title="Seek forward 5s" aria-label="Seek forward 5 seconds" onClick={seek}>
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
        <path d="M21 12a9 9 0 1 1-9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
        <path d="M21 3v5h-5" />
        <text x="12" y="16" textAnchor="middle" fontSize="7.5" fontWeight="700" fill="currentColor" stroke="none" fontFamily="system-ui">5</text>
      </svg>
    </button>
  );
}

const seekSlots = {
  seekBackwardButton: <SeekBack5 />,
  seekForwardButton: <SeekForward5 />,
};

type VideoPlayerProps = {
  src: string | null;
  slug: string;
  title: string;
  poster: string | null;
  captionsSrc?: string | null;
};

export function VideoPlayer({ src, slug, title, poster, captionsSrc }: VideoPlayerProps) {
  const playerRef = usePlayerRef();
  const hasFired = useRef(false);

  function handlePlay() {
    if (hasFired.current) return;
    hasFired.current = true;
    fetch(`/api/videos/${slug}/view`, { method: "POST" }).catch(() => {});
  }

  if (!src) {
    return (
      <div className="relative aspect-video bg-black rounded-lg overflow-hidden border border-[var(--card-border)] flex items-center justify-center text-text-tertiary">
        Video unavailable
      </div>
    );
  }

  return (
    <div className="vds-wrap relative md:overflow-hidden md:rounded-lg shadow-[0_10px_40px_rgba(0,0,0,0.25)] md:border md:border-[var(--card-border)]">
      <MediaPlayer
        ref={playerRef}
        title={title}
        src={src}
        crossOrigin
        playsInline
        aspectRatio="16/9"
        storage="tracer-player"
        onPlay={handlePlay}
      >
        <MediaProvider>
          {poster && <Poster className="vds-poster" src={poster} alt={title} />}
          {/*
            Always render the Track so the captions button is always present
            in the controls layout — otherwise vidstack hides it and the rest
            of the controls collapse to the left when there is no transcript yet.
            The captions.vtt route returns a valid empty VTT when no segments exist.
          */}
          <Track
            kind="subtitles"
            src={captionsSrc ?? `/v/${slug}/captions.vtt`}
            label="Transcript"
            language="en"
            default
          />
        </MediaProvider>
        <DefaultVideoLayout
          icons={defaultLayoutIcons}
          playbackRates={PLAYBACK_RATES}
          slots={{
            downloadButton: <SpeedMenu />,
            googleCastButton: null,
            airPlayButton: null,
            ...seekSlots,
          }}
        />
      </MediaPlayer>
    </div>
  );
}

export function ShareActions({ src }: { src: string | null }) {
  const [copied, setCopied] = useState(false);

  function copyLink() {
    navigator.clipboard.writeText(window.location.href);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="flex flex-wrap items-center gap-3">
      <button onClick={copyLink} className="btn-gradient">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
          <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
        </svg>
        {copied ? "Link copied!" : "Copy link"}
      </button>
      {src && (
        <a href={src} download className="btn-ghost">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
            <polyline points="7 10 12 15 17 10" />
            <line x1="12" y1="15" x2="12" y2="3" />
          </svg>
          Download
        </a>
      )}
    </div>
  );
}
