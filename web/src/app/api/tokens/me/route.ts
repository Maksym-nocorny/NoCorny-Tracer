import { NextRequest, NextResponse } from "next/server";
import { verifyBearerToken } from "@/lib/tokens";

// GET /api/tokens/me — validate a bearer token, return the owning user
// Used by the macOS app to confirm token is valid and display account info
export async function GET(req: NextRequest) {
  const user = await verifyBearerToken(req);
  if (!user) {
    return NextResponse.json({ error: "Invalid token" }, { status: 401 });
  }
  return NextResponse.json({
    email: user.email,
    name: user.name,
    image: user.image,
  });
}
