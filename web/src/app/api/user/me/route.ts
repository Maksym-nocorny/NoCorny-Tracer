import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth";
import { db } from "@/lib/db";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

// GET /api/user/me — returns the current signed-in user's profile
export async function GET() {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  const [row] = await db
    .select({
      id: users.id,
      name: users.name,
      email: users.email,
      image: users.image,
    })
    .from(users)
    .where(eq(users.id, session.user.id))
    .limit(1);
  if (!row) {
    return NextResponse.json({ error: "Not found" }, { status: 404 });
  }
  return NextResponse.json(row);
}

// PATCH /api/user/me — update display name and/or image URL
export async function PATCH(req: NextRequest) {
  const session = await auth();
  if (!session?.user?.id) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = await req.json().catch(() => null);
  const name = typeof body?.name === "string" ? body.name.trim() : undefined;
  const image = typeof body?.image === "string" ? body.image.trim() : undefined;

  const patch: { name?: string | null; image?: string | null; updatedAt: Date } = {
    updatedAt: new Date(),
  };
  if (name !== undefined) patch.name = name.length > 0 ? name.slice(0, 120) : null;
  if (image !== undefined) patch.image = image.length > 0 ? image : null;

  const [updated] = await db
    .update(users)
    .set(patch)
    .where(eq(users.id, session.user.id))
    .returning({
      id: users.id,
      name: users.name,
      email: users.email,
      image: users.image,
    });

  return NextResponse.json(updated);
}
