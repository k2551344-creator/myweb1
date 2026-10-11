import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "ANY BOXING · 센터 관리",
  description: "회원부터 구독, 출석까지. 복싱·피트니스 센터 관리 테스트 공간.",
  other: {
    "codex-preview": "development",
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="ko">
      <body className="antialiased">{children}</body>
    </html>
  );
}
