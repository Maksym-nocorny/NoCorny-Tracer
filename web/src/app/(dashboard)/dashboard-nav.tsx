"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { signOut } from "next-auth/react";
import type { User } from "next-auth";

const NAV_ITEMS = [
  { href: "/dashboard", label: "Videos", icon: VideoIcon },
  { href: "/dashboard/settings", label: "Settings", icon: GearIcon },
];

export function DashboardNav({ user }: { user: User }) {
  const pathname = usePathname();

  return (
    <aside className="hidden md:flex md:flex-col w-60 shrink-0 border-r border-[var(--card-border)] bg-bg-primary">
      <div className="px-6 py-6">
        <Link
          href="/dashboard"
          className="font-heading text-xl font-bold gradient-text"
        >
          NoCorny Tracer
        </Link>
      </div>

      <nav className="flex-1 px-3">
        <ul className="flex flex-col gap-1">
          {NAV_ITEMS.map(({ href, label, icon: Icon }) => {
            const active =
              href === "/dashboard"
                ? pathname === "/dashboard"
                : pathname?.startsWith(href);
            return (
              <li key={href}>
                <Link
                  href={href}
                  className={
                    "flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors " +
                    (active
                      ? "bg-bg-card text-text-primary"
                      : "text-text-secondary hover:text-text-primary hover:bg-bg-card/60")
                  }
                >
                  <Icon active={!!active} />
                  {label}
                </Link>
              </li>
            );
          })}
        </ul>
      </nav>

      <div className="border-t border-[var(--card-border)] p-4">
        <div className="flex items-center gap-3">
          {user.image ? (
            <img
              src={user.image}
              alt=""
              className="w-9 h-9 rounded-full shrink-0"
            />
          ) : (
            <div className="w-9 h-9 rounded-full bg-brand text-text-alt flex items-center justify-center text-sm font-bold shrink-0">
              {user.name?.[0] || user.email?.[0] || "?"}
            </div>
          )}
          <div className="min-w-0 flex-1">
            <div className="text-sm font-semibold text-text-primary truncate">
              {user.name || user.email}
            </div>
            <button
              onClick={() => signOut({ callbackUrl: "/" })}
              className="text-xs text-text-tertiary hover:text-brand-red transition-colors cursor-pointer"
            >
              Sign out
            </button>
          </div>
        </div>
      </div>
    </aside>
  );
}

export function MobileDashboardBar({ user }: { user: User }) {
  return (
    <div className="md:hidden flex items-center justify-between h-14 px-4 border-b border-[var(--card-border)] bg-bg-primary">
      <Link href="/dashboard" className="font-heading text-lg font-bold gradient-text">
        NoCorny Tracer
      </Link>
      <div className="flex items-center gap-3">
        <Link
          href="/dashboard"
          className="text-sm font-medium text-text-secondary hover:text-text-primary"
        >
          Videos
        </Link>
        <Link
          href="/dashboard/settings"
          className="text-sm font-medium text-text-secondary hover:text-text-primary"
        >
          Settings
        </Link>
        {user.image ? (
          <img src={user.image} alt="" className="w-8 h-8 rounded-full" />
        ) : (
          <div className="w-8 h-8 rounded-full bg-brand text-text-alt flex items-center justify-center text-sm font-bold">
            {user.name?.[0] || user.email?.[0] || "?"}
          </div>
        )}
      </div>
    </div>
  );
}

function VideoIcon({ active }: { active: boolean }) {
  return (
    <svg
      className={active ? "text-brand" : ""}
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="m15.75 10.5 4.72-4.72a.75.75 0 0 1 1.28.53v11.38a.75.75 0 0 1-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 0 0 2.25-2.25v-9a2.25 2.25 0 0 0-2.25-2.25h-9A2.25 2.25 0 0 0 2.25 7.5v9a2.25 2.25 0 0 0 2.25 2.25z" />
    </svg>
  );
}

function GearIcon({ active }: { active: boolean }) {
  return (
    <svg
      className={active ? "text-brand" : ""}
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.75"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.646.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.333.183-.582.495-.644.869l-.214 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.02-.397-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z" />
      <path d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
    </svg>
  );
}
