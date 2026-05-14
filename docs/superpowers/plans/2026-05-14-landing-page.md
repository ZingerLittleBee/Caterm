# Caterm Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Next.js 15 + Tailwind v4 landing page at `apps/landing/` with cinematic HTML terminal animations, dark-only theme, and `next-intl` en/zh i18n.

**Architecture:** Standalone Next.js app inside the existing Bun monorepo (`apps/*` workspace). App Router with `[locale]` route group, all marketing content in a single composed page at `/[locale]`. Components organized by section under `src/components/`. No UI library — pure Tailwind. Server components by default; only animations + language switcher are `'use client'`.

**Tech Stack:** Next.js 15, React 19, TypeScript, Tailwind CSS v4, next-intl 3.x, Bun.

**Spec:** `docs/superpowers/specs/2026-05-14-landing-page-design.md`

**Testing strategy:** This is a presentational marketing page. Unit tests would be low-value; instead, every UI task ends with a **manual visual smoke** step (the developer or a subagent loads the dev server, navigates to the section, confirms it renders without console errors and matches the spec). Type safety is enforced by `bun run check-types` and lint by `bun x ultracite check`.

---

## File map (high-level)

```
apps/landing/
├── package.json
├── next.config.mjs
├── tsconfig.json
├── postcss.config.mjs
├── .gitignore
├── README.md
├── messages/{en,zh}.json
└── src/
    ├── middleware.ts                ← next-intl locale negotiation
    ├── app/
    │   ├── [locale]/
    │   │   ├── layout.tsx
    │   │   ├── page.tsx             ← composes every section
    │   │   └── not-found.tsx
    │   ├── globals.css
    │   └── favicon.ico (existing or empty)
    ├── i18n/
    │   ├── routing.ts
    │   └── request.ts
    ├── lib/
    │   └── cn.ts
    ├── components/
    │   ├── nav/{TopNav,LangSwitcher}.tsx
    │   ├── hero/Hero.tsx
    │   ├── terminal/{TerminalWindow,TerminalAnimation,frames}.{tsx,ts}
    │   ├── features/{FeatureGrid,FeatureCard}.tsx
    │   ├── sections/{SyncDeepDive,SyncAnimation,SftpDeepDive,SftpAnimation,CapabilityStrip,OpenSource}.tsx
    │   ├── footer/Footer.tsx
    │   └── icons/*.tsx
```

---

## Task 1: Scaffold `apps/landing` with Next.js 15 + Tailwind v4 + next-intl

**Goal:** Get a stub page rendering at `http://localhost:3003/en` and `http://localhost:3003/zh` with dark background and one heading. Subsequent tasks add components.

**Files:**
- Create: `apps/landing/package.json`
- Create: `apps/landing/next.config.mjs`
- Create: `apps/landing/tsconfig.json`
- Create: `apps/landing/postcss.config.mjs`
- Create: `apps/landing/.gitignore`
- Create: `apps/landing/README.md`
- Create: `apps/landing/src/middleware.ts`
- Create: `apps/landing/src/i18n/routing.ts`
- Create: `apps/landing/src/i18n/request.ts`
- Create: `apps/landing/src/app/globals.css`
- Create: `apps/landing/src/app/[locale]/layout.tsx`
- Create: `apps/landing/src/app/[locale]/page.tsx`
- Create: `apps/landing/src/app/[locale]/not-found.tsx`
- Create: `apps/landing/src/lib/cn.ts`
- Create: `apps/landing/messages/en.json`
- Create: `apps/landing/messages/zh.json`

- [ ] **Step 1.1: Create `apps/landing/package.json`**

```json
{
  "name": "landing",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "next dev --turbopack -p 3003",
    "build": "next build",
    "start": "next start -p 3003",
    "check-types": "tsc --noEmit"
  },
  "dependencies": {
    "next": "^15.0.0",
    "next-intl": "^3.26.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4.0.0",
    "@types/node": "catalog:",
    "@types/react": "^19.0.0",
    "@types/react-dom": "^19.0.0",
    "tailwindcss": "^4.0.0",
    "typescript": "catalog:"
  }
}
```

- [ ] **Step 1.2: Create `apps/landing/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": false,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
```

- [ ] **Step 1.3: Create `apps/landing/next.config.mjs`**

```js
import createNextIntlPlugin from "next-intl/plugin";

const withNextIntl = createNextIntlPlugin("./src/i18n/request.ts");

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
};

export default withNextIntl(nextConfig);
```

- [ ] **Step 1.4: Create `apps/landing/postcss.config.mjs`**

```js
export default {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};
```

- [ ] **Step 1.5: Create `apps/landing/.gitignore`**

```
node_modules
.next
out
dist
.env*
!.env.example
.DS_Store
next-env.d.ts
```

- [ ] **Step 1.6: Create `apps/landing/README.md`**

```markdown
# Caterm Landing Page

Marketing site for Caterm. Next.js 15 + Tailwind CSS v4 + next-intl (en, zh). Dark-only.

## Dev

```bash
bun install
bun run --filter landing dev
```

Then open http://localhost:3003 (redirects to `/en` or `/zh`).
```

- [ ] **Step 1.7: Create `apps/landing/src/i18n/routing.ts`**

```ts
import { defineRouting } from "next-intl/routing";
import { createNavigation } from "next-intl/navigation";

export const routing = defineRouting({
  locales: ["en", "zh"],
  defaultLocale: "en",
  localePrefix: "always",
});

export const { Link, redirect, usePathname, useRouter, getPathname } =
  createNavigation(routing);
```

- [ ] **Step 1.8: Create `apps/landing/src/i18n/request.ts`**

```ts
import { hasLocale } from "next-intl";
import { getRequestConfig } from "next-intl/server";
import { routing } from "./routing";

export default getRequestConfig(async ({ requestLocale }) => {
  const requested = await requestLocale;
  const locale = hasLocale(routing.locales, requested)
    ? requested
    : routing.defaultLocale;

  return {
    locale,
    messages: (await import(`../../messages/${locale}.json`)).default,
  };
});
```

- [ ] **Step 1.9: Create `apps/landing/src/middleware.ts`**

```ts
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";

export default createMiddleware(routing);

export const config = {
  matcher: ["/((?!api|_next|_vercel|.*\\..*).*)"],
};
```

- [ ] **Step 1.10: Create `apps/landing/src/lib/cn.ts`**

```ts
export function cn(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(" ");
}
```

- [ ] **Step 1.11: Create `apps/landing/src/app/globals.css`**

```css
@import "tailwindcss";

@theme {
  --color-bg: #0a0a0a;
  --color-surface: #111111;
  --color-surface-hi: #1a1a1a;
  --color-border: #262626;
  --color-text: #fafafa;
  --color-text-muted: #a3a3a3;
  --color-accent: #22d3ee;
  --color-accent-soft: #0e7490;

  --font-sans: ui-sans-serif, system-ui, -apple-system, "SF Pro Text",
    "Helvetica Neue", Arial, sans-serif;
  --font-mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas,
    monospace;
}

html,
body {
  background: var(--color-bg);
  color: var(--color-text);
  font-family: var(--font-sans);
  -webkit-font-smoothing: antialiased;
}

::selection {
  background: color-mix(in oklab, var(--color-accent) 35%, transparent);
  color: var(--color-text);
}

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.001ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.001ms !important;
  }
}
```

- [ ] **Step 1.12: Create `apps/landing/src/app/[locale]/layout.tsx`**

```tsx
import type { Metadata } from "next";
import { NextIntlClientProvider, hasLocale } from "next-intl";
import { setRequestLocale } from "next-intl/server";
import { notFound } from "next/navigation";
import { routing } from "@/i18n/routing";
import "../globals.css";

export const metadata: Metadata = {
  title: "Caterm — Native macOS SSH terminal",
  description:
    "The SSH terminal that feels like home on macOS. Native Swift. Ghostty-powered. iCloud-synced. Open source.",
};

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export default async function LocaleLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (!hasLocale(routing.locales, locale)) {
    notFound();
  }
  setRequestLocale(locale);

  return (
    <html className="dark" lang={locale}>
      <body className="min-h-screen bg-[var(--color-bg)] text-[var(--color-text)]">
        <NextIntlClientProvider>{children}</NextIntlClientProvider>
      </body>
    </html>
  );
}
```

- [ ] **Step 1.13: Create `apps/landing/src/app/[locale]/page.tsx` (stub)**

```tsx
import { setRequestLocale } from "next-intl/server";
import { getTranslations } from "next-intl/server";

export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("hero");

  return (
    <main className="mx-auto max-w-6xl px-6 py-32 lg:px-8">
      <h1 className="text-5xl font-semibold tracking-tight md:text-7xl">
        {t("tagline")}
      </h1>
      <p className="mt-6 text-lg text-[var(--color-text-muted)]">
        {t("sub")}
      </p>
    </main>
  );
}
```

- [ ] **Step 1.14: Create `apps/landing/src/app/[locale]/not-found.tsx`**

```tsx
export default function NotFound() {
  return (
    <main className="mx-auto max-w-6xl px-6 py-32 lg:px-8">
      <h1 className="text-3xl font-semibold">404</h1>
      <p className="mt-3 text-[var(--color-text-muted)]">Page not found.</p>
    </main>
  );
}
```

- [ ] **Step 1.15: Create `apps/landing/messages/en.json`**

```json
{
  "hero": {
    "tagline": "The SSH terminal that feels like home on macOS.",
    "sub": "Native Swift. Ghostty-powered. iCloud-synced. Open source."
  }
}
```

- [ ] **Step 1.16: Create `apps/landing/messages/zh.json`**

```json
{
  "hero": {
    "tagline": "属于 macOS 的原生 SSH 终端。",
    "sub": "Swift 原生，Ghostty 驱动，iCloud 同步，开源自由。"
  }
}
```

- [ ] **Step 1.17: Install dependencies + verify the dev server**

Run from the repo root:

```bash
bun install
```

Expected: `apps/landing` is picked up by the `apps/*` workspace glob and dependencies install.

Then:

```bash
bun run --filter landing dev
```

Expected: server boots on port 3003.

In a separate terminal:

```bash
curl -sI http://localhost:3003/ | head -1
curl -s http://localhost:3003/en | grep -o "feels like home" | head -1
curl -s http://localhost:3003/zh | grep -o "属于 macOS" | head -1
```

Expected: `HTTP/1.1 307` (redirect to a locale), then "feels like home" and "属于 macOS" appear in the rendered output.

Stop the dev server (Ctrl+C in the dev-server terminal) after verification.

- [ ] **Step 1.18: Run type check + lint**

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
```

Expected: both pass with zero errors. (If ultracite flags issues, run `bun x ultracite fix apps/landing` and re-check.)

- [ ] **Step 1.19: Commit**

```bash
git add apps/landing
git commit -m "feat(landing): scaffold Next.js 15 + Tailwind v4 + next-intl app"
```

---

## Task 2: TopNav + LangSwitcher

**Files:**
- Create: `apps/landing/src/components/nav/TopNav.tsx`
- Create: `apps/landing/src/components/nav/LangSwitcher.tsx`
- Modify: `apps/landing/messages/en.json` — add `nav` namespace
- Modify: `apps/landing/messages/zh.json` — add `nav` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx` — render `<TopNav />`

- [ ] **Step 2.1: Add nav messages to `apps/landing/messages/en.json`**

Merge into the existing top-level object:

```json
{
  "nav": {
    "features": "Features",
    "sync": "Sync",
    "openSource": "Open Source",
    "github": "GitHub",
    "githubStarsAria": "Star Caterm on GitHub",
    "languageAria": "Switch language",
    "english": "English",
    "chinese": "中文"
  }
}
```

- [ ] **Step 2.2: Add nav messages to `apps/landing/messages/zh.json`**

```json
{
  "nav": {
    "features": "功能",
    "sync": "同步",
    "openSource": "开源",
    "github": "GitHub",
    "githubStarsAria": "在 GitHub 给 Caterm 点 Star",
    "languageAria": "切换语言",
    "english": "English",
    "chinese": "中文"
  }
}
```

- [ ] **Step 2.3: Create `apps/landing/src/components/nav/LangSwitcher.tsx`**

```tsx
"use client";

import { useLocale, useTranslations } from "next-intl";
import { usePathname, useRouter } from "@/i18n/routing";
import { routing } from "@/i18n/routing";
import { cn } from "@/lib/cn";

export function LangSwitcher() {
  const t = useTranslations("nav");
  const router = useRouter();
  const pathname = usePathname();
  const current = useLocale();

  function setLocale(next: string) {
    document.cookie = `NEXT_LOCALE=${next}; path=/; max-age=31536000; samesite=lax`;
    router.replace(pathname, { locale: next as (typeof routing.locales)[number] });
  }

  return (
    <div
      aria-label={t("languageAria")}
      className="flex items-center gap-1 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] p-0.5 text-xs"
      role="group"
    >
      {routing.locales.map((loc) => (
        <button
          aria-pressed={current === loc}
          className={cn(
            "rounded-full px-2.5 py-1 transition",
            current === loc
              ? "bg-[var(--color-surface-hi)] text-[var(--color-text)]"
              : "text-[var(--color-text-muted)] hover:text-[var(--color-text)]",
          )}
          key={loc}
          onClick={() => setLocale(loc)}
          type="button"
        >
          {loc === "en" ? t("english") : t("chinese")}
        </button>
      ))}
    </div>
  );
}
```

- [ ] **Step 2.4: Create `apps/landing/src/components/nav/TopNav.tsx`**

```tsx
import { useTranslations } from "next-intl";
import { LangSwitcher } from "./LangSwitcher";

const GITHUB_URL = "https://github.com/ZingerLittleBee/caterm";

export function TopNav() {
  const t = useTranslations("nav");

  return (
    <header className="sticky top-0 z-50 border-b border-[var(--color-border)]/60 bg-[var(--color-bg)]/70 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6 lg:px-8">
        <a
          className="flex items-center gap-2 font-semibold tracking-tight"
          href="#top"
        >
          <span
            aria-hidden="true"
            className="inline-block h-2.5 w-2.5 rounded-full bg-[var(--color-accent)]"
          />
          Caterm
        </a>

        <nav
          aria-label="Primary"
          className="hidden items-center gap-8 text-sm text-[var(--color-text-muted)] md:flex"
        >
          <a className="hover:text-[var(--color-text)]" href="#features">
            {t("features")}
          </a>
          <a className="hover:text-[var(--color-text)]" href="#sync">
            {t("sync")}
          </a>
          <a className="hover:text-[var(--color-text)]" href="#open-source">
            {t("openSource")}
          </a>
        </nav>

        <div className="flex items-center gap-3">
          <LangSwitcher />
          <a
            aria-label={t("githubStarsAria")}
            className="inline-flex h-8 items-center gap-1.5 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] px-3 text-xs text-[var(--color-text)] hover:border-[var(--color-accent)]"
            href={GITHUB_URL}
            rel="noopener noreferrer"
            target="_blank"
          >
            <svg
              aria-hidden="true"
              className="h-3.5 w-3.5"
              fill="currentColor"
              viewBox="0 0 24 24"
            >
              <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.58.11.79-.25.79-.56v-2.02c-3.2.7-3.88-1.37-3.88-1.37-.52-1.33-1.27-1.69-1.27-1.69-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.18 1.76 1.18 1.02 1.75 2.67 1.24 3.32.95.1-.74.4-1.24.73-1.53-2.55-.29-5.24-1.28-5.24-5.7 0-1.26.45-2.29 1.18-3.09-.12-.29-.51-1.46.11-3.05 0 0 .96-.31 3.16 1.18a10.96 10.96 0 0 1 5.76 0c2.19-1.49 3.15-1.18 3.15-1.18.63 1.59.23 2.76.11 3.05.74.8 1.18 1.83 1.18 3.09 0 4.43-2.69 5.41-5.26 5.69.41.36.78 1.05.78 2.12v3.15c0 .31.21.68.8.56C20.22 21.38 23.5 17.08 23.5 12 23.5 5.65 18.35.5 12 .5z" />
            </svg>
            {t("github")}
            <span aria-hidden="true" className="text-[var(--color-text-muted)]">
              ★ —
            </span>
          </a>
        </div>
      </div>
    </header>
  );
}
```

- [ ] **Step 2.5: Wire TopNav into the page**

Modify `apps/landing/src/app/[locale]/page.tsx`:

```tsx
import { setRequestLocale, getTranslations } from "next-intl/server";
import { TopNav } from "@/components/nav/TopNav";

export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = await getTranslations("hero");

  return (
    <>
      <TopNav />
      <main className="mx-auto max-w-6xl px-6 py-32 lg:px-8" id="top">
        <h1 className="text-5xl font-semibold tracking-tight md:text-7xl">
          {t("tagline")}
        </h1>
        <p className="mt-6 text-lg text-[var(--color-text-muted)]">
          {t("sub")}
        </p>
      </main>
    </>
  );
}
```

- [ ] **Step 2.6: Verify**

Start `bun run --filter landing dev`. Open `http://localhost:3003/en`:
- Sticky nav present at top, with logo dot + Caterm wordmark, three anchor links, language switcher (EN active), GitHub pill button.
- Click `中文` in the switcher → URL changes to `/zh`, page content swaps to Chinese.
- Click `EN` → back to `/en`.
- No console errors.

Run:
```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
```
Both pass.

- [ ] **Step 2.7: Commit**

```bash
git add apps/landing
git commit -m "feat(landing): top nav and language switcher"
```

---

## Task 3: Hero section (without animation — animation is Task 4)

**Files:**
- Create: `apps/landing/src/components/hero/Hero.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — add hero CTAs + system req
- Modify: `apps/landing/src/app/[locale]/page.tsx` — render `<Hero />`

- [ ] **Step 3.1: Extend `apps/landing/messages/en.json` hero namespace**

Replace the existing `hero` block with:

```json
{
  "hero": {
    "tagline": "The SSH terminal that feels like home on macOS.",
    "sub": "Native Swift. Ghostty-powered. iCloud-synced. Open source.",
    "ctaPrimary": "Star on GitHub",
    "ctaSecondary": "Download for macOS",
    "requirements": "macOS 14 Sonoma or later · Apple Silicon & Intel"
  }
}
```

- [ ] **Step 3.2: Extend `apps/landing/messages/zh.json` hero namespace**

```json
{
  "hero": {
    "tagline": "属于 macOS 的原生 SSH 终端。",
    "sub": "Swift 原生，Ghostty 驱动，iCloud 同步，开源自由。",
    "ctaPrimary": "在 GitHub 点 Star",
    "ctaSecondary": "下载 macOS 版",
    "requirements": "需要 macOS 14 Sonoma 或更高版本 · 支持 Apple Silicon 与 Intel"
  }
}
```

- [ ] **Step 3.3: Create `apps/landing/src/components/hero/Hero.tsx`**

```tsx
import { useTranslations } from "next-intl";

const GITHUB_URL = "https://github.com/ZingerLittleBee/caterm";

export function Hero({ rightSlot }: { rightSlot: React.ReactNode }) {
  const t = useTranslations("hero");

  return (
    <section
      className="relative mx-auto max-w-6xl px-6 pt-20 pb-24 lg:px-8 lg:pt-28 lg:pb-32"
      id="top"
    >
      <div
        aria-hidden="true"
        className="-z-10 pointer-events-none absolute inset-0 bg-[radial-gradient(ellipse_at_top,_rgba(34,211,238,0.08),_transparent_60%)]"
      />
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
        <div>
          <h1 className="text-balance font-semibold text-5xl text-[var(--color-text)] leading-[1.05] tracking-tight md:text-7xl">
            {t("tagline")}
          </h1>
          <p className="mt-6 max-w-xl text-balance text-[var(--color-text-muted)] text-lg leading-relaxed">
            {t("sub")}
          </p>
          <div className="mt-10 flex flex-wrap items-center gap-3">
            <a
              className="inline-flex h-11 items-center gap-2 rounded-full bg-[var(--color-text)] px-6 font-medium text-[var(--color-bg)] text-sm transition hover:bg-white"
              href={GITHUB_URL}
              rel="noopener noreferrer"
              target="_blank"
            >
              {t("ctaPrimary")}
              <span aria-hidden="true">→</span>
            </a>
            <a
              className="inline-flex h-11 items-center gap-2 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] px-6 font-medium text-[var(--color-text)] text-sm transition hover:border-[var(--color-accent)]"
              href="#download"
            >
              {t("ctaSecondary")}
            </a>
          </div>
          <p className="mt-5 text-[var(--color-text-muted)] text-xs">
            {t("requirements")}
          </p>
        </div>

        <div className="relative">{rightSlot}</div>
      </div>
    </section>
  );
}
```

- [ ] **Step 3.4: Render `<Hero />` with a placeholder right slot in the page**

Modify `apps/landing/src/app/[locale]/page.tsx`:

```tsx
import { setRequestLocale } from "next-intl/server";
import { TopNav } from "@/components/nav/TopNav";
import { Hero } from "@/components/hero/Hero";

export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return (
    <>
      <TopNav />
      <Hero
        rightSlot={
          <div className="aspect-[4/3] w-full rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)]" />
        }
      />
    </>
  );
}
```

- [ ] **Step 3.5: Verify**

`bun run --filter landing dev`. Open `/en`:
- Two-column hero on desktop, stacked on narrow.
- Tagline, sub, primary "Star on GitHub" button, secondary "Download for macOS" button, requirements line.
- Right column shows an empty rounded surface placeholder.
- Switch to `/zh` — Chinese text renders.

Run:
```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
```

- [ ] **Step 3.6: Commit**

```bash
git add apps/landing
git commit -m "feat(landing): hero section copy and CTAs"
```

---

## Task 4: Terminal animation (cinematic auto-loop)

This is the most complex component. Implement it as a fully self-contained `'use client'` widget.

**Files:**
- Create: `apps/landing/src/components/terminal/TerminalWindow.tsx`
- Create: `apps/landing/src/components/terminal/frames.ts`
- Create: `apps/landing/src/components/terminal/TerminalAnimation.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `terminal` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx` — replace placeholder with `<TerminalAnimation />`

- [ ] **Step 4.1: Add terminal translations to `apps/landing/messages/en.json`**

```json
{
  "terminal": {
    "title": "caterm — ssh deploy@prod",
    "tabProd": "prod",
    "tabStaging": "staging",
    "commentConnect": "# Connect to your prod server",
    "statusConnected": "✓ Connected via Ghostty engine",
    "toastSync": "iCloud sync · just now"
  }
}
```

- [ ] **Step 4.2: Add terminal translations to `apps/landing/messages/zh.json`**

```json
{
  "terminal": {
    "title": "caterm — ssh deploy@prod",
    "tabProd": "prod",
    "tabStaging": "staging",
    "commentConnect": "# 连接到你的生产环境",
    "statusConnected": "✓ 通过 Ghostty 引擎已连接",
    "toastSync": "iCloud 已同步 · 刚刚"
  }
}
```

- [ ] **Step 4.3: Create `apps/landing/src/components/terminal/TerminalWindow.tsx`**

```tsx
import type React from "react";

export function TerminalWindow({
  title,
  tabs,
  activeTab,
  children,
}: {
  title: string;
  tabs: Array<{ id: string; label: string }>;
  activeTab: string;
  children: React.ReactNode;
}) {
  return (
    <div className="overflow-hidden rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] shadow-[0_30px_80px_-20px_rgba(34,211,238,0.15)]">
      <div className="flex items-center gap-3 border-b border-[var(--color-border)] bg-[var(--color-surface-hi)] px-4 py-2.5">
        <div className="flex items-center gap-1.5" aria-hidden="true">
          <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
          <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
          <span className="h-3 w-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="flex-1 truncate text-center text-[var(--color-text-muted)] text-xs">
          {title}
        </div>
        <div className="w-12" aria-hidden="true" />
      </div>
      <div className="flex gap-1 border-b border-[var(--color-border)] bg-[var(--color-surface-hi)] px-3 py-1.5">
        {tabs.map((tab) => {
          const active = tab.id === activeTab;
          return (
            <div
              className={`flex items-center gap-1.5 rounded-md px-2.5 py-1 text-xs transition ${
                active
                  ? "bg-[var(--color-surface)] text-[var(--color-text)]"
                  : "text-[var(--color-text-muted)]"
              }`}
              key={tab.id}
            >
              <span
                aria-hidden="true"
                className={`h-1.5 w-1.5 rounded-full ${
                  active ? "bg-[var(--color-accent)]" : "bg-[var(--color-border)]"
                }`}
              />
              {tab.label}
            </div>
          );
        })}
      </div>
      <div className="relative min-h-[340px] bg-[var(--color-bg)] p-5 font-mono text-[13px] leading-relaxed">
        {children}
      </div>
    </div>
  );
}
```

- [ ] **Step 4.4: Create `apps/landing/src/components/terminal/frames.ts`**

```ts
export type Line =
  | { kind: "type"; text: string; className?: string }
  | { kind: "instant"; text: string; className?: string }
  | { kind: "htop" }
  | { kind: "progress"; label: string }
  | { kind: "blank" };

export type Frame = {
  prompt: string;
  lines: Line[];
  activeTab: "prod" | "staging";
  toast?: string;
  durationMs: number;
};

export function buildFrames(t: {
  commentConnect: string;
  statusConnected: string;
  toastSync: string;
}): Frame[] {
  const prompt = "deploy@prod ~ $";

  return [
    {
      prompt,
      activeTab: "prod",
      durationMs: 1200,
      lines: [
        { kind: "type", text: t.commentConnect, className: "text-[var(--color-text-muted)]" },
      ],
    },
    {
      prompt,
      activeTab: "prod",
      durationMs: 1400,
      lines: [
        { kind: "instant", text: t.commentConnect, className: "text-[var(--color-text-muted)]" },
        { kind: "type", text: "ssh deploy@prod.caterm.dev" },
      ],
    },
    {
      prompt,
      activeTab: "prod",
      durationMs: 800,
      lines: [
        { kind: "instant", text: t.commentConnect, className: "text-[var(--color-text-muted)]" },
        { kind: "instant", text: "ssh deploy@prod.caterm.dev" },
        { kind: "instant", text: t.statusConnected, className: "text-[var(--color-accent)]" },
      ],
    },
    {
      prompt,
      activeTab: "prod",
      durationMs: 1100,
      lines: [
        { kind: "instant", text: t.statusConnected, className: "text-[var(--color-accent)]" },
        { kind: "type", text: "htop" },
      ],
    },
    {
      prompt,
      activeTab: "prod",
      durationMs: 2000,
      lines: [
        { kind: "instant", text: t.statusConnected, className: "text-[var(--color-accent)]" },
        { kind: "instant", text: "htop" },
        { kind: "htop" },
      ],
    },
    {
      prompt,
      activeTab: "prod",
      durationMs: 1200,
      lines: [
        { kind: "instant", text: "^C", className: "text-[var(--color-text-muted)]" },
        { kind: "type", text: "sftp put release.tar.gz" },
      ],
    },
    {
      prompt,
      activeTab: "prod",
      durationMs: 1800,
      lines: [
        { kind: "instant", text: "sftp put release.tar.gz" },
        { kind: "progress", label: "release.tar.gz" },
      ],
    },
    {
      prompt,
      activeTab: "staging",
      durationMs: 1500,
      toast: t.toastSync,
      lines: [
        { kind: "instant", text: "sftp put release.tar.gz", className: "text-[var(--color-text-muted)]" },
        { kind: "instant", text: "✓ uploaded · 24.6 MB", className: "text-[var(--color-accent)]" },
      ],
    },
    {
      prompt,
      activeTab: "staging",
      durationMs: 1500,
      lines: [],
    },
  ];
}
```

- [ ] **Step 4.5: Create `apps/landing/src/components/terminal/TerminalAnimation.tsx`**

```tsx
"use client";

import { useEffect, useMemo, useState } from "react";
import { useTranslations } from "next-intl";
import { TerminalWindow } from "./TerminalWindow";
import { buildFrames, type Frame, type Line } from "./frames";

const TYPE_SPEED_MS = 30;

export function TerminalAnimation() {
  const t = useTranslations("terminal");
  const frames = useMemo<Frame[]>(
    () =>
      buildFrames({
        commentConnect: t("commentConnect"),
        statusConnected: t("statusConnected"),
        toastSync: t("toastSync"),
      }),
    [t],
  );

  const [frameIdx, setFrameIdx] = useState(0);
  const [typedChars, setTypedChars] = useState(0);

  const frame = frames[frameIdx];

  useEffect(() => {
    const lastLine = frame.lines.at(-1);
    const typing = lastLine?.kind === "type";

    if (typing) {
      const target = (lastLine as Extract<Line, { kind: "type" }>).text.length;
      if (typedChars < target) {
        const timer = setTimeout(() => {
          setTypedChars((n) => n + 1);
        }, TYPE_SPEED_MS);
        return () => clearTimeout(timer);
      }
    }

    const timer = setTimeout(() => {
      setTypedChars(0);
      setFrameIdx((i) => (i + 1) % frames.length);
    }, frame.durationMs);
    return () => clearTimeout(timer);
  }, [frame, frames.length, typedChars]);

  return (
    <TerminalWindow
      activeTab={frame.activeTab}
      tabs={[
        { id: "prod", label: t("tabProd") },
        { id: "staging", label: t("tabStaging") },
      ]}
      title={t("title")}
    >
      <pre className="m-0 whitespace-pre-wrap font-mono text-[var(--color-text)] text-[13px]">
        {frame.lines.map((line, idx) => {
          const isLast = idx === frame.lines.length - 1;
          if (line.kind === "blank") {
            return <div className="h-4" key={idx} />;
          }
          if (line.kind === "htop") {
            return <HtopBlock key={idx} />;
          }
          if (line.kind === "progress") {
            return <ProgressLine key={idx} label={line.label} />;
          }
          const text =
            line.kind === "type" && isLast
              ? line.text.slice(0, typedChars)
              : line.text;
          return (
            <div className={line.className} key={idx}>
              <span className="mr-2 text-[var(--color-text-muted)]">
                {frame.prompt}
              </span>
              {text}
              {line.kind === "type" && isLast ? <Caret /> : null}
            </div>
          );
        })}
      </pre>

      {frame.toast ? (
        <div className="absolute right-4 bottom-4 animate-[fadeIn_400ms_ease-out] rounded-full border border-[var(--color-border)] bg-[var(--color-surface-hi)] px-3 py-1.5 text-[11px] text-[var(--color-text-muted)]">
          {frame.toast}
        </div>
      ) : null}

      <style>{`
        @keyframes fadeIn {
          from { opacity: 0; transform: translateY(4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @keyframes blink {
          0%, 49% { opacity: 1; }
          50%, 100% { opacity: 0; }
        }
        @keyframes pulseBar {
          0%, 100% { width: 30%; }
          50% { width: 78%; }
        }
        @keyframes pulseBar2 {
          0%, 100% { width: 55%; }
          50% { width: 22%; }
        }
        @keyframes pulseBar3 {
          0%, 100% { width: 18%; }
          50% { width: 64%; }
        }
        @keyframes pulseBar4 {
          0%, 100% { width: 72%; }
          50% { width: 41%; }
        }
        @keyframes progressFill {
          from { width: 0%; }
          to { width: 100%; }
        }
      `}</style>
    </TerminalWindow>
  );
}

function Caret() {
  return (
    <span
      aria-hidden="true"
      className="ml-0.5 inline-block h-3.5 w-1.5 translate-y-0.5 bg-[var(--color-accent)]"
      style={{ animation: "blink 1s steps(1,end) infinite" }}
    />
  );
}

function HtopBlock() {
  return (
    <div className="mt-1 space-y-1">
      {(["pulseBar", "pulseBar2", "pulseBar3", "pulseBar4"] as const).map(
        (anim, i) => (
          <div className="flex items-center gap-2" key={anim}>
            <span className="w-12 text-[var(--color-text-muted)]">{`CPU${i}`}</span>
            <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-[var(--color-surface-hi)]">
              <div
                className="h-full bg-[var(--color-accent)]"
                style={{ animation: `${anim} 1.8s ease-in-out infinite` }}
              />
            </div>
          </div>
        ),
      )}
    </div>
  );
}

function ProgressLine({ label }: { label: string }) {
  return (
    <div className="mt-1 flex items-center gap-2">
      <span className="text-[var(--color-text-muted)]">{label}</span>
      <div className="h-1.5 w-48 overflow-hidden rounded-full bg-[var(--color-surface-hi)]">
        <div
          className="h-full bg-[var(--color-accent)]"
          style={{ animation: "progressFill 1.5s ease-out forwards" }}
        />
      </div>
    </div>
  );
}
```

- [ ] **Step 4.6: Wire `<TerminalAnimation />` into the page**

Modify `apps/landing/src/app/[locale]/page.tsx`:

```tsx
import { setRequestLocale } from "next-intl/server";
import { TopNav } from "@/components/nav/TopNav";
import { Hero } from "@/components/hero/Hero";
import { TerminalAnimation } from "@/components/terminal/TerminalAnimation";

export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return (
    <>
      <TopNav />
      <Hero rightSlot={<TerminalAnimation />} />
    </>
  );
}
```

- [ ] **Step 4.7: Verify in browser**

`bun run --filter landing dev`. Open `/en`:
- Terminal window in the hero right column.
- Traffic-light dots, title `caterm — ssh deploy@prod`, two tabs (prod, staging).
- Typewriter playback runs through frames; htop bars animate; progress bar fills; sync toast appears when staging tab becomes active.
- After full cycle (~12 s), it loops cleanly.
- Switch to `/zh` — comments + status + toast appear in Chinese; commands stay English.
- Toggle macOS System Settings → Accessibility → "Reduce motion" ON and reload: animation collapses to a static frame (acceptable; `prefers-reduced-motion` applies via the global CSS rule).

No console errors.

Run:
```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
```

- [ ] **Step 4.8: Commit**

```bash
git add apps/landing
git commit -m "feat(landing): cinematic terminal animation in hero"
```

---

## Task 5: Feature grid (3×2 cards)

**Files:**
- Create: `apps/landing/src/components/icons/index.tsx`
- Create: `apps/landing/src/components/features/FeatureCard.tsx`
- Create: `apps/landing/src/components/features/FeatureGrid.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `features` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx` — render `<FeatureGrid />`

- [ ] **Step 5.1: Add `features` translations to `apps/landing/messages/en.json`**

```json
{
  "features": {
    "sectionTitle": "Built for macOS power users",
    "sectionSub": "Every detail tuned to the platform. No Electron, no compromises.",
    "items": {
      "swift": {
        "title": "Native Swift",
        "body": "AppKit, Metal, Core Text. Launch instantly, scroll at 120 Hz."
      },
      "ghostty": {
        "title": "Powered by Ghostty",
        "body": "The fastest terminal renderer on macOS, embedded as libghostty."
      },
      "icloud": {
        "title": "iCloud sync",
        "body": "Hosts, credentials, settings, and snippets sync via CloudKit. Zero config."
      },
      "sftp": {
        "title": "SFTP transfers",
        "body": "Drag, drop, push, pull. A real file drawer next to your shell."
      },
      "bookmarks": {
        "title": "Remote bookmarks",
        "body": "Pin remote directories. One click to jump back where you left off."
      },
      "snippets": {
        "title": "Command snippets",
        "body": "A palette of your reusable commands. Synced. Searchable. Yours."
      }
    }
  }
}
```

- [ ] **Step 5.2: Add `features` translations to `apps/landing/messages/zh.json`**

```json
{
  "features": {
    "sectionTitle": "为 macOS 重度用户打造",
    "sectionSub": "每个细节都为平台量身定制。不是 Electron，没有妥协。",
    "items": {
      "swift": {
        "title": "Swift 原生",
        "body": "AppKit、Metal、Core Text。秒开，120Hz 顺滑滚动。"
      },
      "ghostty": {
        "title": "Ghostty 驱动",
        "body": "macOS 上最快的终端渲染器，以 libghostty 形式集成。"
      },
      "icloud": {
        "title": "iCloud 同步",
        "body": "主机、凭据、设置、片段全部通过 CloudKit 同步。零配置。"
      },
      "sftp": {
        "title": "SFTP 文件传输",
        "body": "拖拽、上传、下载。Shell 旁边就是一个真正的文件抽屉。"
      },
      "bookmarks": {
        "title": "远程书签",
        "body": "固定远程目录。一键跳回上次离开的地方。"
      },
      "snippets": {
        "title": "命令片段",
        "body": "你的可复用命令调色板。已同步、可搜索、归你所有。"
      }
    }
  }
}
```

- [ ] **Step 5.3: Create `apps/landing/src/components/icons/index.tsx`**

```tsx
import type { SVGProps } from "react";

type Props = SVGProps<SVGSVGElement>;

const base: Props = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.5,
  strokeLinecap: "round",
  strokeLinejoin: "round",
  viewBox: "0 0 24 24",
  "aria-hidden": "true",
};

export function SwiftIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M5 5l4.5 4.5M19 5l-6.5 6.5L7 6m12 6c-2 4-6 7-12 7" />
    </svg>
  );
}

export function GhosttyIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M5 11a7 7 0 0114 0v8l-3-2-3 2-3-2-3 2-2-2v-6z" />
      <circle cx="10" cy="11" r="0.8" fill="currentColor" />
      <circle cx="14" cy="11" r="0.8" fill="currentColor" />
    </svg>
  );
}

export function ICloudIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M7 18a4 4 0 010-8 5 5 0 019.6-1.4A4 4 0 0117 18H7z" />
    </svg>
  );
}

export function SftpIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M4 7h7l2 2h7v10H4z" />
      <path d="M12 12v6m0 0l-2-2m2 2l2-2" />
    </svg>
  );
}

export function BookmarkIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M7 4h10v17l-5-3-5 3V4z" />
    </svg>
  );
}

export function SnippetIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M4 6h16M4 12h10M4 18h16" />
    </svg>
  );
}

export function PortForwardIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M3 12h12m0 0l-4-4m4 4l-4 4M19 5v14" />
    </svg>
  );
}

export function JumpHostIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <circle cx="5" cy="12" r="2" />
      <circle cx="12" cy="6" r="2" />
      <circle cx="19" cy="12" r="2" />
      <circle cx="12" cy="18" r="2" />
      <path d="M6.5 11l4-3.5M13.5 7.5l4 3M13.5 16.5l4-3M10.5 16l-4-3" />
    </svg>
  );
}

export function KeychainIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <circle cx="8" cy="14" r="3" />
      <path d="M10.5 12l8-8 2 2-2 2 2 2-3 1" />
    </svg>
  );
}

export function ControlMasterIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <path d="M4 7h16M4 12h16M4 17h10" />
      <circle cx="18" cy="17" r="2" />
    </svg>
  );
}

export function ThemeIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <circle cx="12" cy="12" r="8" />
      <path d="M12 4a8 8 0 010 16 4 4 0 010-8 4 4 0 000-8z" />
    </svg>
  );
}

export function AskpassIcon(props: Props) {
  return (
    <svg {...base} {...props}>
      <rect height="10" rx="2" width="14" x="5" y="11" />
      <path d="M8 11V7a4 4 0 018 0v4" />
      <circle cx="12" cy="16" fill="currentColor" r="0.8" />
    </svg>
  );
}
```

- [ ] **Step 5.4: Create `apps/landing/src/components/features/FeatureCard.tsx`**

```tsx
import type React from "react";

export function FeatureCard({
  icon,
  title,
  body,
}: {
  icon: React.ReactNode;
  title: string;
  body: string;
}) {
  return (
    <div className="group rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-6 transition hover:border-[var(--color-accent)]/60">
      <div className="mb-4 inline-flex h-10 w-10 items-center justify-center rounded-xl border border-[var(--color-border)] bg-[var(--color-surface-hi)] text-[var(--color-accent)]">
        <div className="h-5 w-5">{icon}</div>
      </div>
      <h3 className="font-semibold text-base text-[var(--color-text)]">
        {title}
      </h3>
      <p className="mt-2 text-[var(--color-text-muted)] text-sm leading-relaxed">
        {body}
      </p>
    </div>
  );
}
```

- [ ] **Step 5.5: Create `apps/landing/src/components/features/FeatureGrid.tsx`**

```tsx
import { useTranslations } from "next-intl";
import {
  BookmarkIcon,
  GhosttyIcon,
  ICloudIcon,
  SftpIcon,
  SnippetIcon,
  SwiftIcon,
} from "@/components/icons";
import { FeatureCard } from "./FeatureCard";

export function FeatureGrid() {
  const t = useTranslations("features");

  const items = [
    { key: "swift", icon: <SwiftIcon /> },
    { key: "ghostty", icon: <GhosttyIcon /> },
    { key: "icloud", icon: <ICloudIcon /> },
    { key: "sftp", icon: <SftpIcon /> },
    { key: "bookmarks", icon: <BookmarkIcon /> },
    { key: "snippets", icon: <SnippetIcon /> },
  ] as const;

  return (
    <section
      className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8"
      id="features"
    >
      <div className="max-w-2xl">
        <h2 className="text-balance font-semibold text-3xl tracking-tight md:text-4xl">
          {t("sectionTitle")}
        </h2>
        <p className="mt-4 text-[var(--color-text-muted)] text-lg">
          {t("sectionSub")}
        </p>
      </div>
      <div className="mt-14 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        {items.map(({ key, icon }) => (
          <FeatureCard
            body={t(`items.${key}.body`)}
            icon={icon}
            key={key}
            title={t(`items.${key}.title`)}
          />
        ))}
      </div>
    </section>
  );
}
```

- [ ] **Step 5.6: Wire `<FeatureGrid />` into the page**

Modify `apps/landing/src/app/[locale]/page.tsx`:

```tsx
import { setRequestLocale } from "next-intl/server";
import { TopNav } from "@/components/nav/TopNav";
import { Hero } from "@/components/hero/Hero";
import { TerminalAnimation } from "@/components/terminal/TerminalAnimation";
import { FeatureGrid } from "@/components/features/FeatureGrid";

export default async function HomePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return (
    <>
      <TopNav />
      <Hero rightSlot={<TerminalAnimation />} />
      <FeatureGrid />
    </>
  );
}
```

- [ ] **Step 5.7: Verify + type check + lint + commit**

Browser: scroll past hero → 6 cards in a 3-column grid (2 on md, 1 on sm) with icons + title + body. Switch locale to verify translations.

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
git add apps/landing
git commit -m "feat(landing): feature grid with monoline icons"
```

---

## Task 6: Sync deep-dive (`SyncDeepDive` + `SyncAnimation`)

**Files:**
- Create: `apps/landing/src/components/sections/SyncAnimation.tsx`
- Create: `apps/landing/src/components/sections/SyncDeepDive.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `sync` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx`

- [ ] **Step 6.1: Add `sync` translations to en.json**

```json
{
  "sync": {
    "eyebrow": "iCloud Sync",
    "title": "Your terminal, on every Mac you own.",
    "body": "Caterm uses CloudKit to sync hosts, credentials, settings, snippets, and themes between your Macs. Encrypted by Apple, scoped to your iCloud account. Nothing to set up, no account to create.",
    "bullets": [
      "Hosts and credentials, end-to-end via Keychain + iCloud",
      "Per-host themes and terminal settings",
      "Command snippets palette, instantly available everywhere"
    ]
  }
}
```

- [ ] **Step 6.2: Add `sync` translations to zh.json**

```json
{
  "sync": {
    "eyebrow": "iCloud 同步",
    "title": "你的终端，跟随你的每一台 Mac。",
    "body": "Caterm 通过 CloudKit 在你的多台 Mac 之间同步主机、凭据、设置、命令片段和主题。由 Apple 加密，限定在你的 iCloud 账户内。无需配置，也无需新建账户。",
    "bullets": [
      "主机与凭据通过 Keychain + iCloud 端到端同步",
      "每个主机独立的主题与终端设置",
      "命令片段调色板，立即在所有设备可用"
    ]
  }
}
```

- [ ] **Step 6.3: Create `apps/landing/src/components/sections/SyncAnimation.tsx`**

```tsx
"use client";

export function SyncAnimation() {
  return (
    <div
      aria-hidden="true"
      className="relative mx-auto flex h-72 max-w-md items-center justify-between"
    >
      <Mac side="left" />
      <Cloud />
      <Mac side="right" />

      <style>{`
        @keyframes dotLeft {
          0%, 100% { transform: translateX(0); opacity: 0; }
          10% { opacity: 1; }
          50% { transform: translateX(60px); opacity: 1; }
          90% { opacity: 0; }
        }
        @keyframes dotRight {
          0%, 100% { transform: translateX(0); opacity: 0; }
          10% { opacity: 1; }
          50% { transform: translateX(-60px); opacity: 1; }
          90% { opacity: 0; }
        }
        @keyframes ledBlink {
          0%, 80%, 100% { opacity: 0.2; }
          90% { opacity: 1; }
        }
        @keyframes ledBlinkAlt {
          0%, 30%, 100% { opacity: 0.2; }
          40% { opacity: 1; }
        }
      `}</style>
    </div>
  );
}

function Mac({ side }: { side: "left" | "right" }) {
  return (
    <div className="relative flex flex-col items-center gap-2">
      <div className="relative h-24 w-36 rounded-xl border border-[var(--color-border)] bg-[var(--color-surface)] p-2">
        <div className="h-full w-full rounded-md bg-[var(--color-bg)] p-1.5">
          <div className="mb-1 h-1 w-6 rounded-full bg-[var(--color-border)]" />
          <div className="mb-1 h-1 w-12 rounded-full bg-[var(--color-border)]" />
          <div
            className="mb-1 h-1 w-10 rounded-full bg-[var(--color-accent)]"
            style={{
              animation: `${side === "left" ? "ledBlink" : "ledBlinkAlt"} 2.4s infinite`,
            }}
          />
          <div className="h-1 w-8 rounded-full bg-[var(--color-border)]" />
        </div>
      </div>
      <div className="h-1 w-20 rounded-b-md bg-[var(--color-border)]" />
    </div>
  );
}

function Cloud() {
  return (
    <div className="relative flex flex-col items-center">
      <div className="flex h-16 w-20 items-center justify-center rounded-full border border-[var(--color-border)] bg-[var(--color-surface-hi)] text-[var(--color-accent)]">
        <svg
          aria-hidden="true"
          className="h-7 w-7"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          viewBox="0 0 24 24"
        >
          <path
            d="M7 18a4 4 0 010-8 5 5 0 019.6-1.4A4 4 0 0117 18H7z"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>

      <div className="-translate-y-1/2 -translate-x-[80px] absolute top-1/2 left-1/2">
        <span
          className="block h-1.5 w-1.5 rounded-full bg-[var(--color-accent)]"
          style={{ animation: "dotLeft 2.4s ease-in-out infinite" }}
        />
      </div>
      <div className="-translate-y-1/2 absolute top-1/2 left-1/2 translate-x-[20px]">
        <span
          className="block h-1.5 w-1.5 rounded-full bg-[var(--color-accent)]"
          style={{
            animation: "dotRight 2.4s ease-in-out infinite",
            animationDelay: "1.2s",
          }}
        />
      </div>
    </div>
  );
}
```

- [ ] **Step 6.4: Create `apps/landing/src/components/sections/SyncDeepDive.tsx`**

```tsx
import { useTranslations } from "next-intl";
import { SyncAnimation } from "./SyncAnimation";

export function SyncDeepDive() {
  const t = useTranslations("sync");
  const bullets = t.raw("bullets") as string[];

  return (
    <section
      className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8"
      id="sync"
    >
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-20">
        <div>
          <p className="font-medium text-[var(--color-accent)] text-sm">
            {t("eyebrow")}
          </p>
          <h2 className="mt-2 text-balance font-semibold text-3xl tracking-tight md:text-4xl">
            {t("title")}
          </h2>
          <p className="mt-5 text-[var(--color-text-muted)] text-lg leading-relaxed">
            {t("body")}
          </p>
          <ul className="mt-8 space-y-3 text-[var(--color-text)] text-sm">
            {bullets.map((bullet) => (
              <li className="flex gap-3" key={bullet}>
                <span
                  aria-hidden="true"
                  className="mt-1.5 inline-block h-1.5 w-1.5 flex-none rounded-full bg-[var(--color-accent)]"
                />
                <span className="text-[var(--color-text-muted)]">{bullet}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-10">
          <SyncAnimation />
        </div>
      </div>
    </section>
  );
}
```

- [ ] **Step 6.5: Wire into page**

Add `import { SyncDeepDive } from "@/components/sections/SyncDeepDive";` to `page.tsx` and render `<SyncDeepDive />` after `<FeatureGrid />`.

- [ ] **Step 6.6: Verify + type check + lint + commit**

Browser: section renders below the feature grid. Two columns on desktop. Animation plays: little dots travel between Macs and the cloud, LED in each Mac blinks at staggered timing. Switch locale to confirm.

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
git add apps/landing
git commit -m "feat(landing): iCloud sync deep-dive section"
```

---

## Task 7: SFTP & Bookmarks deep-dive

**Files:**
- Create: `apps/landing/src/components/sections/SftpAnimation.tsx`
- Create: `apps/landing/src/components/sections/SftpDeepDive.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `sftp` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx`

- [ ] **Step 7.1: Add `sftp` translations to en.json**

```json
{
  "sftp": {
    "eyebrow": "SFTP & Bookmarks",
    "title": "Files where your shell already is.",
    "body": "Pop the file drawer beside any session to browse, upload, and download. Pin the remote paths you keep returning to — they live in the bookmark popover, one keystroke away.",
    "fileList": ["release.tar.gz", "Caddyfile", "logs", "deploy.sh", "env.production"],
    "bookmarks": ["prod / etc", "staging / var/log", "bastion / home"]
  }
}
```

- [ ] **Step 7.2: Add `sftp` translations to zh.json**

```json
{
  "sftp": {
    "eyebrow": "SFTP 与书签",
    "title": "文件就在 Shell 旁边。",
    "body": "在任意会话旁打开文件抽屉，浏览、上传、下载一气呵成。把你常用的远程路径固定在书签弹窗里，一个按键就能跳回去。",
    "fileList": ["release.tar.gz", "Caddyfile", "logs", "deploy.sh", "env.production"],
    "bookmarks": ["prod / etc", "staging / var/log", "bastion / home"]
  }
}
```

- [ ] **Step 7.3: Create `apps/landing/src/components/sections/SftpAnimation.tsx`**

```tsx
"use client";

import { useTranslations } from "next-intl";

export function SftpAnimation() {
  const t = useTranslations("sftp");
  const files = t.raw("fileList") as string[];
  const bookmarks = t.raw("bookmarks") as string[];

  return (
    <div
      aria-hidden="true"
      className="relative h-80 overflow-hidden rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-4"
    >
      <div className="flex h-full gap-3">
        <div
          className="w-40 flex-none rounded-lg border border-[var(--color-border)] bg-[var(--color-bg)] p-3 opacity-0"
          style={{ animation: "slideInDrawer 1200ms ease-out 200ms forwards" }}
        >
          <div className="mb-3 flex items-center justify-between">
            <span className="text-[var(--color-text-muted)] text-[11px] uppercase tracking-wider">
              files
            </span>
            <span className="text-[var(--color-text-muted)] text-[11px]">
              /var/www
            </span>
          </div>
          <ul className="space-y-1 font-mono text-[12px]">
            {files.map((file, i) => (
              <li
                className="flex items-center gap-1.5 truncate text-[var(--color-text)] opacity-0"
                key={file}
                style={{
                  animation: `fadeFile 400ms ease-out forwards`,
                  animationDelay: `${600 + i * 120}ms`,
                }}
              >
                <span className="text-[var(--color-text-muted)]">·</span>
                <span className="truncate">{file}</span>
              </li>
            ))}
          </ul>
        </div>

        <div className="relative flex-1 rounded-lg border border-[var(--color-border)] bg-[var(--color-bg)] p-3 font-mono text-[12px]">
          <div className="space-y-1 text-[var(--color-text-muted)]">
            <div>
              <span className="text-[var(--color-text)]">deploy@prod</span> ~ $ ls
            </div>
            <div>release.tar.gz Caddyfile logs</div>
            <div>
              <span className="text-[var(--color-text)]">deploy@prod</span> ~ ${" "}
              <span
                className="ml-1 inline-block h-3 w-1.5 translate-y-0.5 bg-[var(--color-accent)] align-middle"
                style={{ animation: "blink 1s steps(1,end) infinite" }}
              />
            </div>
          </div>

          <div
            className="absolute top-4 right-4 w-44 rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-hi)] p-2 opacity-0 shadow-[0_8px_30px_rgba(0,0,0,0.35)]"
            style={{
              animation: "fadeBookmark 500ms ease-out 1400ms forwards",
            }}
          >
            <div className="mb-1.5 text-[var(--color-text-muted)] text-[10px] uppercase tracking-wider">
              bookmarks
            </div>
            <ul className="space-y-1 text-[11px]">
              {bookmarks.map((bookmark, i) => (
                <li
                  className="flex items-center gap-1.5 rounded-md bg-[var(--color-surface)] px-2 py-1 text-[var(--color-text)] opacity-0"
                  key={bookmark}
                  style={{
                    animation: "fadeFile 400ms ease-out forwards",
                    animationDelay: `${1600 + i * 150}ms`,
                  }}
                >
                  <span className="h-1.5 w-1.5 rounded-full bg-[var(--color-accent)]" />
                  {bookmark}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </div>

      <style>{`
        @keyframes slideInDrawer {
          from { transform: translateX(-110%); opacity: 0; }
          to { transform: translateX(0); opacity: 1; }
        }
        @keyframes fadeFile {
          from { opacity: 0; transform: translateY(4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @keyframes fadeBookmark {
          from { opacity: 0; transform: translateY(-6px); }
          to { opacity: 1; transform: translateY(0); }
        }
        @keyframes blink {
          0%, 49% { opacity: 1; }
          50%, 100% { opacity: 0; }
        }
      `}</style>
    </div>
  );
}
```

- [ ] **Step 7.4: Create `apps/landing/src/components/sections/SftpDeepDive.tsx`**

```tsx
import { useTranslations } from "next-intl";
import { SftpAnimation } from "./SftpAnimation";

export function SftpDeepDive() {
  const t = useTranslations("sftp");

  return (
    <section
      className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8"
      id="sftp"
    >
      <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-20">
        <div className="order-2 lg:order-1">
          <SftpAnimation />
        </div>
        <div className="order-1 lg:order-2">
          <p className="font-medium text-[var(--color-accent)] text-sm">
            {t("eyebrow")}
          </p>
          <h2 className="mt-2 text-balance font-semibold text-3xl tracking-tight md:text-4xl">
            {t("title")}
          </h2>
          <p className="mt-5 text-[var(--color-text-muted)] text-lg leading-relaxed">
            {t("body")}
          </p>
        </div>
      </div>
    </section>
  );
}
```

- [ ] **Step 7.5: Wire into page**

Add `import { SftpDeepDive } from "@/components/sections/SftpDeepDive";` and render `<SftpDeepDive />` after `<SyncDeepDive />`.

- [ ] **Step 7.6: Verify + type check + lint + commit**

Browser: drawer slides in from the left, files fade in staggered, bookmark popover fades in over the faux terminal. Switch locale.

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
git add apps/landing
git commit -m "feat(landing): sftp + bookmarks deep-dive section"
```

---

## Task 8: Capability strip

**Files:**
- Create: `apps/landing/src/components/sections/CapabilityStrip.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `capabilities` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx`

- [ ] **Step 8.1: Add capabilities translations to en.json**

```json
{
  "capabilities": {
    "title": "And more, where it matters.",
    "items": {
      "portForward": "Port forwarding",
      "jumpHost": "Jump hosts",
      "keychain": "Keychain-backed credentials",
      "controlMaster": "ControlMaster reuse",
      "themes": "Per-host themes",
      "snippets": "Snippet palette",
      "askpass": "Custom askpass"
    }
  }
}
```

- [ ] **Step 8.2: Add capabilities translations to zh.json**

```json
{
  "capabilities": {
    "title": "其他重要细节，也已就绪。",
    "items": {
      "portForward": "端口转发",
      "jumpHost": "跳板机链",
      "keychain": "Keychain 凭据",
      "controlMaster": "ControlMaster 复用",
      "themes": "每主机独立主题",
      "snippets": "命令片段调色板",
      "askpass": "自定义 askpass"
    }
  }
}
```

- [ ] **Step 8.3: Create `apps/landing/src/components/sections/CapabilityStrip.tsx`**

```tsx
import { useTranslations } from "next-intl";
import {
  AskpassIcon,
  ControlMasterIcon,
  JumpHostIcon,
  KeychainIcon,
  PortForwardIcon,
  SnippetIcon,
  ThemeIcon,
} from "@/components/icons";

export function CapabilityStrip() {
  const t = useTranslations("capabilities");

  const items = [
    { key: "portForward", Icon: PortForwardIcon },
    { key: "jumpHost", Icon: JumpHostIcon },
    { key: "keychain", Icon: KeychainIcon },
    { key: "controlMaster", Icon: ControlMasterIcon },
    { key: "themes", Icon: ThemeIcon },
    { key: "snippets", Icon: SnippetIcon },
    { key: "askpass", Icon: AskpassIcon },
  ] as const;

  return (
    <section className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-20 lg:px-8">
      <h2 className="text-center text-[var(--color-text-muted)] text-sm uppercase tracking-[0.2em]">
        {t("title")}
      </h2>
      <ul className="mt-8 flex flex-wrap items-center justify-center gap-3">
        {items.map(({ key, Icon }) => (
          <li
            className="inline-flex items-center gap-2 rounded-full border border-[var(--color-border)] bg-[var(--color-surface)] px-4 py-2 text-[var(--color-text)] text-sm"
            key={key}
          >
            <span className="text-[var(--color-accent)]">
              <Icon className="h-4 w-4" />
            </span>
            {t(`items.${key}`)}
          </li>
        ))}
      </ul>
    </section>
  );
}
```

- [ ] **Step 8.4: Wire into page**

Add `import { CapabilityStrip } from "@/components/sections/CapabilityStrip";` and render `<CapabilityStrip />` after `<SftpDeepDive />`.

- [ ] **Step 8.5: Verify + type check + lint + commit**

Browser: a single horizontal flex-wrap row of 7 chips with icon + label. Switch locale.

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
git add apps/landing
git commit -m "feat(landing): capability strip"
```

---

## Task 9: Open Source section

**Files:**
- Create: `apps/landing/src/components/sections/OpenSource.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `openSource` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx`

- [ ] **Step 9.1: Add openSource translations to en.json**

```json
{
  "openSource": {
    "eyebrow": "Open Source",
    "title": "Made in the open.",
    "body": "Caterm is open source under the MIT license. The whole macOS app, including the libghostty integration and CloudKit sync layer, is in one Swift Package. Fork it, build it, ship it.",
    "cta": "View on GitHub",
    "stack": {
      "label": "What's inside",
      "items": ["Swift 5.10", "libghostty", "CloudKit", "Keychain Services", "russh-style ssh", "Swift Package Manager"]
    }
  }
}
```

- [ ] **Step 9.2: Add openSource translations to zh.json**

```json
{
  "openSource": {
    "eyebrow": "开源",
    "title": "完全开放，由你掌控。",
    "body": "Caterm 以 MIT 协议开源。整个 macOS 应用——包括 libghostty 集成与 CloudKit 同步层——都在一个 Swift Package 里。Fork、构建、发布，都由你决定。",
    "cta": "在 GitHub 查看",
    "stack": {
      "label": "技术栈一览",
      "items": ["Swift 5.10", "libghostty", "CloudKit", "Keychain Services", "russh 风格 SSH", "Swift Package Manager"]
    }
  }
}
```

- [ ] **Step 9.3: Create `apps/landing/src/components/sections/OpenSource.tsx`**

```tsx
import { useTranslations } from "next-intl";

const GITHUB_URL = "https://github.com/ZingerLittleBee/caterm";

export function OpenSource() {
  const t = useTranslations("openSource");
  const stackItems = t.raw("stack.items") as string[];

  return (
    <section
      className="mx-auto max-w-6xl border-[var(--color-border)] border-t px-6 py-24 md:py-32 lg:px-8"
      id="open-source"
    >
      <div className="grid gap-12 lg:grid-cols-2 lg:gap-20">
        <div>
          <p className="font-medium text-[var(--color-accent)] text-sm">
            {t("eyebrow")}
          </p>
          <h2 className="mt-2 text-balance font-semibold text-3xl tracking-tight md:text-4xl">
            {t("title")}
          </h2>
          <p className="mt-5 text-[var(--color-text-muted)] text-lg leading-relaxed">
            {t("body")}
          </p>
          <a
            className="mt-8 inline-flex h-11 items-center gap-2 rounded-full bg-[var(--color-text)] px-6 font-medium text-[var(--color-bg)] text-sm transition hover:bg-white"
            href={GITHUB_URL}
            rel="noopener noreferrer"
            target="_blank"
          >
            {t("cta")}
            <span aria-hidden="true">→</span>
          </a>
        </div>
        <div className="rounded-2xl border border-[var(--color-border)] bg-[var(--color-surface)] p-8">
          <p className="text-[var(--color-text-muted)] text-xs uppercase tracking-[0.2em]">
            {t("stack.label")}
          </p>
          <ul className="mt-5 grid grid-cols-2 gap-3">
            {stackItems.map((item) => (
              <li
                className="rounded-lg border border-[var(--color-border)] bg-[var(--color-surface-hi)] px-3 py-2 font-mono text-[var(--color-text)] text-xs"
                key={item}
              >
                {item}
              </li>
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}
```

- [ ] **Step 9.4: Wire into page**

Add `import { OpenSource } from "@/components/sections/OpenSource";` and render `<OpenSource />` after `<CapabilityStrip />`.

- [ ] **Step 9.5: Verify + type check + lint + commit**

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
git add apps/landing
git commit -m "feat(landing): open source section"
```

---

## Task 10: Footer

**Files:**
- Create: `apps/landing/src/components/footer/Footer.tsx`
- Modify: `apps/landing/messages/{en,zh}.json` — `footer` namespace
- Modify: `apps/landing/src/app/[locale]/page.tsx`

- [ ] **Step 10.1: Add footer translations to en.json**

```json
{
  "footer": {
    "tagline": "Native SSH for macOS.",
    "linksTitle": "Project",
    "links": {
      "features": "Features",
      "github": "GitHub",
      "license": "License",
      "privacy": "Privacy"
    },
    "rights": "© 2026 Caterm. MIT licensed."
  }
}
```

- [ ] **Step 10.2: Add footer translations to zh.json**

```json
{
  "footer": {
    "tagline": "macOS 原生 SSH 工具。",
    "linksTitle": "项目",
    "links": {
      "features": "功能",
      "github": "GitHub",
      "license": "许可协议",
      "privacy": "隐私"
    },
    "rights": "© 2026 Caterm. MIT 协议开源。"
  }
}
```

- [ ] **Step 10.3: Create `apps/landing/src/components/footer/Footer.tsx`**

```tsx
import { useTranslations } from "next-intl";
import { LangSwitcher } from "@/components/nav/LangSwitcher";

const GITHUB_URL = "https://github.com/ZingerLittleBee/caterm";

export function Footer() {
  const t = useTranslations("footer");

  return (
    <footer className="border-[var(--color-border)] border-t">
      <div className="mx-auto grid max-w-6xl gap-10 px-6 py-16 md:grid-cols-3 lg:px-8">
        <div>
          <div className="flex items-center gap-2 font-semibold tracking-tight">
            <span
              aria-hidden="true"
              className="inline-block h-2.5 w-2.5 rounded-full bg-[var(--color-accent)]"
            />
            Caterm
          </div>
          <p className="mt-2 text-[var(--color-text-muted)] text-sm">
            {t("tagline")}
          </p>
        </div>

        <div>
          <p className="font-medium text-[var(--color-text)] text-xs uppercase tracking-[0.2em]">
            {t("linksTitle")}
          </p>
          <ul className="mt-4 space-y-2 text-sm">
            <li>
              <a
                className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
                href="#features"
              >
                {t("links.features")}
              </a>
            </li>
            <li>
              <a
                className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
                href={GITHUB_URL}
                rel="noopener noreferrer"
                target="_blank"
              >
                {t("links.github")}
              </a>
            </li>
            <li>
              <a
                className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
                href={`${GITHUB_URL}/blob/main/LICENSE`}
                rel="noopener noreferrer"
                target="_blank"
              >
                {t("links.license")}
              </a>
            </li>
            <li>
              <a
                className="text-[var(--color-text-muted)] hover:text-[var(--color-text)]"
                href="#privacy"
              >
                {t("links.privacy")}
              </a>
            </li>
          </ul>
        </div>

        <div className="flex flex-col items-start gap-4 md:items-end">
          <LangSwitcher />
          <p className="text-[var(--color-text-muted)] text-xs">{t("rights")}</p>
        </div>
      </div>
    </footer>
  );
}
```

- [ ] **Step 10.4: Wire into page**

Add `import { Footer } from "@/components/footer/Footer";` and render `<Footer />` after `<OpenSource />`.

- [ ] **Step 10.5: Verify + type check + lint + commit**

```bash
bun run --filter landing check-types
bun x ultracite check apps/landing
git add apps/landing
git commit -m "feat(landing): footer"
```

---

## Task 11: Final polish + acceptance check

- [ ] **Step 11.1: Final visual smoke**

Run `bun run --filter landing dev`. In a browser at `http://localhost:3003`:

1. Land on `/`. Confirm 307 redirect to `/en` (or `/zh` if your `Accept-Language` is Chinese).
2. Verify `/en` renders top-to-bottom without console errors:
   - Sticky nav stays visible while scrolling.
   - Hero text + cinematic terminal (auto-loops through ssh → htop → sftp → sync toast).
   - Feature grid with 6 cards.
   - Sync deep-dive with two Mac silhouettes + cloud animation.
   - SFTP deep-dive with sliding drawer + bookmark popover.
   - Capability strip with 7 chips.
   - Open source section with stack badges.
   - Footer with brand, link list, language switcher, copyright.
3. Switch to `/zh` via the nav language switcher. Confirm:
   - URL updates to `/zh`.
   - All copy switches to Chinese (terminal commands stay English; comments + statuses + toast in Chinese).
   - Cookie `NEXT_LOCALE=zh` is set.
4. Reload `/`. Confirm it redirects to `/zh` now (cookie persisted).
5. macOS: System Settings → Accessibility → "Reduce motion" → toggle ON, reload `/en`. Terminal, sync, and SFTP animations collapse to a static end state. Page is still readable.
6. Keyboard test: Tab through the page from the top. Every link / button / language toggle shows a visible focus ring.

- [ ] **Step 11.2: Type check the entire monorepo**

```bash
bun run check-types
```

Expected: every workspace passes, including `landing`.

- [ ] **Step 11.3: Lint full monorepo**

```bash
bun x ultracite check
```

Expected: zero issues. If there are issues only in `apps/landing`, run `bun x ultracite fix apps/landing` and re-check.

- [ ] **Step 11.4: Production build**

```bash
bun run --filter landing build
```

Expected: build succeeds; `.next/` contains the prerendered `/en` and `/zh` pages.

- [ ] **Step 11.5: Final commit (if any uncommitted polish remains)**

```bash
git status
git add -A apps/landing
git diff --cached --stat
git commit -m "chore(landing): final polish for first release" || echo "nothing to commit"
```

---

## Self-review notes

- **Spec coverage:** every section in the spec (TopNav, Hero, FeatureGrid, SyncDeepDive, SftpDeepDive, CapabilityStrip, OpenSource, Footer, dark-only theme, i18n en/zh, terminal animation with prefers-reduced-motion respect, port 3003, monorepo integration) is implemented in tasks 1-10; Task 11 covers acceptance criteria.
- **Types referenced across tasks:** `Frame`, `Line` defined in Task 4 are only used inside Task 4. All other components have no cross-task type dependencies.
- **`prefers-reduced-motion`:** handled globally in `globals.css` (Task 1) so all animation tasks inherit the behavior automatically.
- **Risks:** Tailwind v4 and next-intl 3.26 are recent; if `bun install` fails to resolve, the executor should pin specific patch versions. The `tabsRow` `aria-hidden` could be reconsidered if accessibility audits flag it, but tabs here are purely decorative.
