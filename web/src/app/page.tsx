import Link from "next/link";
import { redirect } from "next/navigation";
import { auth } from "@/lib/auth";

export default async function Home() {
  const session = await auth();

  if (session) redirect("/dashboard");

  return (
    <div className="min-h-screen flex flex-col bg-bg-primary">
      <header className="border-b border-[var(--card-border)]">
        <div className="max-w-6xl mx-auto px-6 flex items-center justify-between h-16">
          <Link href="/" className="font-heading text-xl font-bold gradient-text">
            NoCorny Tracer
          </Link>
          <nav className="flex items-center gap-6">
            <a
              href="https://github.com/Maksym-nocorny/NoCorny-Tracer"
              className="text-sm font-medium text-text-secondary hover:text-text-primary transition-colors"
              target="_blank"
              rel="noreferrer"
            >
              GitHub
            </a>
            {session ? (
              <Link href="/dashboard" className="btn-gradient !py-2 !px-4 text-sm">
                Open dashboard
              </Link>
            ) : (
              <Link
                href="/login"
                className="text-sm font-medium text-text-secondary hover:text-text-primary transition-colors"
              >
                Sign in
              </Link>
            )}
          </nav>
        </div>
      </header>

      <main className="flex-1">
        {/* Hero */}
        <section className="max-w-6xl mx-auto px-6 py-24 md:py-32 text-center">
          <h1 className="font-heading text-4xl md:text-6xl font-bold leading-tight">
            Record your screen.
            <br />
            <span className="gradient-text">Share with one link.</span>
          </h1>
          <p className="mt-6 text-lg text-text-secondary max-w-2xl mx-auto leading-relaxed">
            NoCorny Tracer is a free, open-source screen recorder for macOS.
            Every recording becomes a shareable page — no accounts for your
            viewers, no watermarks, and your files stay in your Dropbox.
          </p>
          <div className="mt-10 flex flex-wrap items-center justify-center gap-3">
            <a
              href="https://github.com/Maksym-nocorny/NoCorny-Tracer/releases/latest"
              className="btn-gradient"
              target="_blank"
              rel="noreferrer"
            >
              Download for macOS
            </a>
            {!session && (
              <Link href="/login" className="btn-ghost">
                Sign in to the web
              </Link>
            )}
          </div>
        </section>

        {/* Screenshot */}
        <section className="max-w-5xl mx-auto px-6 pb-24">
          <div
            className="rounded-2xl overflow-hidden border border-[var(--card-border)] shadow-[0_20px_60px_rgba(62,6,147,0.25)] aspect-[16/10] flex items-center justify-center"
            style={{
              background:
                "linear-gradient(135deg, rgba(62,6,147,0.08), rgba(107,0,222,0.15))",
            }}
          >
            <div className="text-center px-6">
              <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-bg-card border border-[var(--card-border)] text-sm font-medium text-text-secondary">
                <span className="w-2 h-2 rounded-full bg-brand-red animate-pulse" />
                Recording preview · 00:42
              </div>
              <p className="mt-6 font-heading text-2xl font-bold text-text-primary">
                A tiny floating panel — start, pause, and share.
              </p>
              <p className="mt-2 text-text-secondary">
                Menubar timer, global hotkeys, AI-generated titles.
              </p>
            </div>
          </div>
        </section>

        {/* Features */}
        <section className="max-w-6xl mx-auto px-6 pb-24">
          <div className="grid md:grid-cols-3 gap-6">
            <Feature
              title="Free & open source"
              body="No subscriptions, no paywalls. Fork it, audit it, ship it."
            />
            <Feature
              title="Your Dropbox, your files"
              body="Recordings go straight to your Dropbox. We never host your video."
            />
            <Feature
              title="One-click shares"
              body="Get a clean tracer.nocorny.com link the moment you stop recording."
            />
          </div>
        </section>
      </main>

      <footer className="border-t border-[var(--card-border)] py-8">
        <div className="max-w-6xl mx-auto px-6 flex flex-wrap items-center justify-between gap-3 text-sm text-text-tertiary">
          <div>
            Made by{" "}
            <a
              href="https://nocorny.agency"
              target="_blank"
              rel="noreferrer"
              className="hover:text-text-primary transition-colors"
            >
              NoCorny Agency
            </a>
          </div>
          <div className="flex gap-4">
            <a
              href="https://maksym-nocorny.github.io/NoCorny-Tracer/privacy-policy"
              className="hover:text-text-primary transition-colors"
              target="_blank"
              rel="noreferrer"
            >
              Privacy
            </a>
            <a
              href="https://maksym-nocorny.github.io/NoCorny-Tracer/terms-of-service"
              className="hover:text-text-primary transition-colors"
              target="_blank"
              rel="noreferrer"
            >
              Terms
            </a>
          </div>
        </div>
      </footer>
    </div>
  );
}

function Feature({ title, body }: { title: string; body: string }) {
  return (
    <div className="card">
      <h3 className="font-heading font-bold text-text-primary">{title}</h3>
      <p className="mt-2 text-text-secondary leading-relaxed">{body}</p>
    </div>
  );
}
