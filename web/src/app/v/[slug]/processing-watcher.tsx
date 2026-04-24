"use client";

import { useEffect, useRef } from "react";
import type { TranscriptSegment } from "@/lib/db/schema";

export type StatusPayload = {
  processingStatus: string;
  title: string;
  description: string | null;
  transcriptSrt: string | null;
  transcriptSegments: TranscriptSegment[] | null;
  thumbnailUrl: string | null;
};

type Props = {
  slug: string;
  initialStatus: string;
  onReady: (data: StatusPayload) => void;
};

const POLL_INTERVAL_MS = 5000;
const MAX_POLLS = 72; // ~6 minutes then silent give-up

export function ProcessingWatcher({ slug, initialStatus, onReady }: Props) {
  const pollCount = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (initialStatus !== "processing") return;

    async function poll() {
      pollCount.current += 1;
      if (pollCount.current > MAX_POLLS) return;

      try {
        const res = await fetch(`/api/videos/${slug}/status`, {
          cache: "no-store",
        });
        if (res.ok) {
          const data: StatusPayload = await res.json();
          if (data.processingStatus === "ready") {
            onReady(data);
            return;
          }
        }
      } catch {
        // network blip — retry next tick
      }

      timerRef.current = setTimeout(poll, POLL_INTERVAL_MS);
    }

    timerRef.current = setTimeout(poll, POLL_INTERVAL_MS);
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, [slug, initialStatus, onReady]);

  return null;
}
