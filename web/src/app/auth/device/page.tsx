import { auth } from "@/lib/auth";
import { redirect } from "next/navigation";
import { ApproveDeviceForm } from "./approve-form";

const ALLOWED_REDIRECT_PREFIX = "nocornytracer://";

type DeviceSearchParams = Promise<{
  state?: string;
  redirect?: string;
}>;

export default async function DeviceAuthPage({
  searchParams,
}: {
  searchParams: DeviceSearchParams;
}) {
  const { state, redirect: redirectUrl } = await searchParams;

  if (!state || !redirectUrl || !redirectUrl.startsWith(ALLOWED_REDIRECT_PREFIX)) {
    return (
      <main className="min-h-screen flex items-center justify-center p-8">
        <div className="card max-w-md w-full text-center">
          <h1 className="font-heading text-2xl font-bold text-text-primary mb-3">
            Invalid authorization link
          </h1>
          <p className="text-text-secondary">
            This page can only be opened from the NoCorny Tracer desktop app.
          </p>
        </div>
      </main>
    );
  }

  const session = await auth();
  if (!session?.user) {
    const callbackUrl = `/auth/device?state=${encodeURIComponent(
      state
    )}&redirect=${encodeURIComponent(redirectUrl)}`;
    redirect(`/login?callbackUrl=${encodeURIComponent(callbackUrl)}`);
  }

  const user = session.user;

  return (
    <main className="min-h-screen flex items-center justify-center p-8">
      <div className="card max-w-md w-full">
        <div className="text-center mb-6">
          <div
            className="font-heading text-3xl font-bold mb-1"
            style={{
              background:
                "linear-gradient(135deg, var(--gradient-start), var(--gradient-end))",
              WebkitBackgroundClip: "text",
              WebkitTextFillColor: "transparent",
              backgroundClip: "text",
            }}
          >
            NoCorny Tracer
          </div>
          <p className="text-text-secondary text-sm">Authorize desktop app</p>
        </div>

        <div className="flex items-center gap-3 mb-6 p-3 rounded-md bg-bg-neutral">
          {user.image ? (
            <img
              src={user.image}
              alt=""
              className="w-10 h-10 rounded-full"
            />
          ) : (
            <div className="w-10 h-10 rounded-full bg-brand text-text-alt flex items-center justify-center font-bold">
              {(user.name ?? user.email ?? "?").slice(0, 1).toUpperCase()}
            </div>
          )}
          <div className="min-w-0">
            <div className="font-semibold text-text-primary truncate">
              {user.name || user.email}
            </div>
            {user.name && (
              <div className="text-sm text-text-tertiary truncate">
                {user.email}
              </div>
            )}
          </div>
        </div>

        <p className="text-text-secondary mb-6 leading-relaxed">
          The <strong>NoCorny Tracer</strong> desktop app is requesting access
          to your account. Approving will sign you in on this device so new
          recordings can be shared with a one-click link.
        </p>

        <ApproveDeviceForm state={state} redirectUrl={redirectUrl} />
      </div>
    </main>
  );
}
