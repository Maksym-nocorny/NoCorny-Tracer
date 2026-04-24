import type { Metadata } from "next";
import { PT_Sans, Mulish } from "next/font/google";
import "./globals.css";

const ptSans = PT_Sans({
  variable: "--font-heading",
  subsets: ["latin", "cyrillic"],
  weight: ["400", "700"],
});

const mulish = Mulish({
  variable: "--font-body",
  subsets: ["latin", "cyrillic"],
});

export const metadata: Metadata = {
  title: "NoCorny Tracer",
  description: "Screen recordings, instantly shareable",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className={`${ptSans.variable} ${mulish.variable} h-full`}>
      <body className="min-h-full flex flex-col antialiased">{children}</body>
    </html>
  );
}
