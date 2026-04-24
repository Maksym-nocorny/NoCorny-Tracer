"use client";

import {
  createContext,
  useContext,
  useRef,
  type ReactNode,
  type RefObject,
} from "react";
import type { MediaPlayerInstance } from "@vidstack/react";

type PlayerContextValue = {
  playerRef: RefObject<MediaPlayerInstance | null>;
};

const PlayerContext = createContext<PlayerContextValue | null>(null);

export function PlayerProvider({ children }: { children: ReactNode }) {
  const playerRef = useRef<MediaPlayerInstance | null>(null);
  return (
    <PlayerContext.Provider value={{ playerRef }}>
      {children}
    </PlayerContext.Provider>
  );
}

export function usePlayerRef(): RefObject<MediaPlayerInstance | null> {
  const ctx = useContext(PlayerContext);
  if (!ctx) throw new Error("usePlayerRef must be used inside <PlayerProvider>");
  return ctx.playerRef;
}
