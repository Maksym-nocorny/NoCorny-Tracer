import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { videos } from "@/lib/db/schema";
import { eq, and, desc } from "drizzle-orm";
import { LibraryClient } from "./library-client";

export default async function DashboardPage() {
  const session = await auth();
  if (!session?.user?.id) return null;

  const userVideos = await db
    .select()
    .from(videos)
    .where(and(eq(videos.userId, session.user.id), eq(videos.isDeleted, false)))
    .orderBy(desc(videos.createdAt));

  const name =
    session.user.name || session.user.email?.split("@")[0] || "You";

  return (
    <LibraryClient
      videos={userVideos}
      author={{ name, image: session.user.image ?? null }}
    />
  );
}
