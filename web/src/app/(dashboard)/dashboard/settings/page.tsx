import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { dropboxConnections, apiTokens, users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { DropboxConnect } from "./dropbox-connect";
import { ProfileEdit } from "./profile-edit";

export default async function SettingsPage() {
  const session = await auth();
  if (!session?.user?.id) return null;

  const [connection, tokenRow, userRow] = await Promise.all([
    db
      .select()
      .from(dropboxConnections)
      .where(eq(dropboxConnections.userId, session.user.id))
      .limit(1),
    db
      .select({ lastUsedAt: apiTokens.lastUsedAt })
      .from(apiTokens)
      .where(eq(apiTokens.userId, session.user.id))
      .limit(1),
    db
      .select({ name: users.name, email: users.email, image: users.image })
      .from(users)
      .where(eq(users.id, session.user.id))
      .limit(1),
  ]);

  const isConnected = connection.length > 0;
  const desktopSignedIn = tokenRow.length > 0;
  const desktopLastUsed = tokenRow[0]?.lastUsedAt ?? null;
  const profile = userRow[0];

  return (
    <div className="max-w-2xl">
      <h1 className="font-heading text-3xl font-bold text-text-primary mb-8">
        Settings
      </h1>

      {/* Profile */}
      <section className="card mb-6">
        <h2 className="section-heading text-base mb-4">Profile</h2>
        <ProfileEdit
          initialName={profile?.name ?? null}
          initialImage={profile?.image ?? null}
          email={profile?.email ?? session.user.email ?? ""}
          dropboxConnected={isConnected}
        />
      </section>

      {/* Desktop app */}
      <section className="card mb-6">
        <h2 className="section-heading text-base mb-2">Desktop app</h2>
        <p className="text-sm text-text-secondary mb-4">
          {desktopSignedIn
            ? `Connected${desktopLastUsed ? ` · last active ${new Date(desktopLastUsed).toLocaleDateString()}` : ""}.`
            : "No device signed in yet."}
        </p>
        <p className="text-sm text-text-secondary mb-4">
          Download the macOS app and tap{" "}
          <span className="font-semibold">Sign in with Browser</span> in
          Settings — it&apos;ll bring you here automatically.
        </p>
        <a
          href="https://github.com/Maksym-nocorny/NoCorny-Tracer/releases/latest"
          className="btn-ghost"
          target="_blank"
          rel="noreferrer"
        >
          Download for macOS
        </a>
      </section>

      {/* Storage */}
      <section className="card">
        <h2 className="section-heading text-base mb-4">Storage — Dropbox</h2>
        <DropboxConnect
          isConnected={isConnected}
          lastSynced={connection[0]?.lastSyncedAt?.toISOString() ?? null}
        />
      </section>
    </div>
  );
}
