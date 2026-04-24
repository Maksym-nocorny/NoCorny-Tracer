import { redirect } from "next/navigation";
import { auth } from "@/lib/auth";
import { DashboardNav, MobileDashboardBar } from "./dashboard-nav";

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const session = await auth();

  if (!session?.user) {
    redirect("/login");
  }

  return (
    <div className="min-h-screen flex bg-bg-primary">
      <DashboardNav user={session.user} />

      <div className="flex-1 flex flex-col min-w-0">
        <MobileDashboardBar user={session.user} />
        <main className="flex-1 px-6 md:px-10 py-8 max-w-[1400px] w-full">
          {children}
        </main>
      </div>
    </div>
  );
}
