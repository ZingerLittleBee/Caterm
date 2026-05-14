# Caterm Landing Page — Design Spec

**Date:** 2026-05-14
**Status:** Approved (verbal, via brainstorming session)
**Target path:** `apps/landing/`

---

## 1. Goal

Build a marketing / open-source-introduction landing page for the Caterm macOS SSH terminal client. The page lives alongside the existing `apps/web`, `apps/server`, and `apps/macos` projects, has its own Next.js workspace, and is deployable to Vercel.

The primary call to action is **GitHub open-source acquisition** (Star / View Source); secondary CTA is **Download for macOS** (placeholder link for now).

The page must visually showcase the product without using product screenshots — terminal demonstrations are rendered live in HTML/CSS/JS.

---

## 2. Tech stack

| Concern | Choice | Reason |
|---|---|---|
| Framework | **Next.js 15+ App Router** | Modern App Router; matches "Next.js homepage style" requirement |
| Language | TypeScript (strict) | Matches monorepo standard |
| Styling | **Tailwind CSS v4** | Project standard; user requirement |
| UI library | **None** (pure Tailwind + hand-written components) | User decision; avoids generic shadcn look |
| i18n | **next-intl** | App Router-native, route-prefix-based (`/en`, `/zh`) |
| Theming | **Dark only** | Forced via `<html class="dark">` and a single dark token set — no light tokens |
| Package manager | Bun (monorepo standard) | Repo uses Bun |
| Lint/format | Ultracite (Biome) | Repo standard |
| Deployment target | Vercel | Standard Next.js |

### Monorepo integration

- Lives at `apps/landing/` with its own `package.json`.
- Added to root `package.json` workspaces via the existing `apps/*` glob — no root change required.
- Scripts: `dev` (port **3003** — `web` uses 3001, `server` uses 3002), `build`, `start`, `lint`, `check-types`.
- Picked up by root `dev`, `build`, `check-types` via `bun run --filter '*' …`.

---

## 3. Branding & copy

- **Product name:** Caterm
- **Hero tagline (EN):** *The SSH terminal that feels like home on macOS.*
- **Hero sub (EN):** *Native Swift. Ghostty-powered. iCloud-synced. Open source.*
- **Hero tagline (ZH):** *属于 macOS 的原生 SSH 终端。*
- **Hero sub (ZH):** *Swift 原生，Ghostty 驱动，iCloud 同步，开源自由。*

Voice: clean / technical / Next.js-style confident — no hype, no emoji in copy.

---

## 4. Page structure (single-page scroll)

In source order:

1. **TopNav** — sticky, frosted-glass on scroll.
   - Left: Caterm wordmark.
   - Center: anchor links (Features · Sync · Open Source).
   - Right: language switch (EN / 中文), GitHub icon button with star count badge (static `★ —` until wired).
2. **Hero** — two-column on `md+`, stacked on mobile.
   - Left: tagline (h1), sub (lead paragraph), dual CTAs (`Star on GitHub` primary, `Download for macOS` secondary), tiny system requirement line (`macOS 14 Sonoma or later · Apple Silicon & Intel`).
   - Right: **animated terminal window** (see §5).
3. **Feature Grid** — 3×2 grid of cards. Each card: small icon, title, one-sentence description.
   - Native macOS, Built in Swift
   - Powered by Ghostty (Metal-accelerated)
   - iCloud Sync (zero-config)
   - SFTP & File Transfers
   - Remote Bookmarks
   - Command Snippets
4. **Deep-dive A — iCloud Sync** — left copy / right visual.
   - Visual: two stylized Mac windows side-by-side, with an animated cloud icon between them and pulsing arrows showing data sync. Pure SVG + CSS keyframes.
5. **Deep-dive B — SFTP & Bookmarks** — right copy / left visual (alternating layout).
   - Visual: a faux file drawer that slides in from the left of a terminal window, listing remote files; a bookmark popover floats above with chip-styled host names.
6. **Capability strip** — single horizontal row of small chips with monoline icons: Port Forwarding · Jump Hosts · Keychain · ControlMaster · Per-host Themes · Snippets Palette · Custom Askpass.
7. **Open Source section** — heading + two-column subgrid:
   - Left: prose paragraph about open source / MIT / Swift Package Manager.
   - Right: stack badges (Swift, Ghostty, CloudKit, Keychain) and a primary `View on GitHub` button.
8. **Footer** — three columns: brand + tagline (left), nav links (center: Features, GitHub, License, Privacy), language switcher + copyright (right).

### Layout system

- Container: `max-w-6xl mx-auto px-6 lg:px-8`
- Section vertical rhythm: `py-24 md:py-32` for major sections, `py-16` for strip
- Type scale: hero h1 `text-5xl md:text-7xl`, section h2 `text-3xl md:text-4xl`
- Color tokens (dark only):
  - `bg`: `#0a0a0a` (page)
  - `surface`: `#111111`, `surface-hi`: `#1a1a1a` (cards/terminal chrome)
  - `border`: `#262626`
  - `text`: `#fafafa`, `text-muted`: `#a3a3a3`
  - `accent`: `#22d3ee` (cyan — terminal-feel accent for CTAs and highlights)

---

## 5. Hero terminal animation (cinematic auto-loop)

Pure HTML/CSS/JS — **no external libs**, no canvas.

### Structure

```
<TerminalWindow>
  <Titlebar>          ← three traffic-light circles + center title "caterm — ssh deploy@prod"
  <TabsRow>           ← two tabs: [● prod ‹active›] [● staging]
  <Pane>              ← <pre> with monospace, lines rendered character-by-character
</TerminalWindow>
```

### Timeline (≈ 12 s, then crossfade and restart)

| t (s) | Action |
|---|---|
| 0.0 – 1.2 | Typewriter: `# Connect to your prod server` (the comment is i18n'd) |
| 1.2 – 2.4 | Typewriter: `ssh deploy@prod.caterm.dev` → newline |
| 2.4 – 3.0 | Status line fade-in: `✓ Connected via Ghostty engine` |
| 3.0 – 4.2 | Typewriter: `htop` → newline |
| 4.2 – 6.0 | Fake `htop` block: 4 CPU bars with CSS `@keyframes` width oscillation |
| 6.0 – 6.3 | Ctrl+C indicator + prompt returns |
| 6.3 – 7.5 | Typewriter: `sftp put release.tar.gz` |
| 7.5 – 9.0 | Progress bar fills 0→100% with byte counter |
| 9.0 – 10.0 | Tab indicator switches → small toast `iCloud sync · just now` slides in |
| 10.0 – 12.0 | Hold, fade everything to 0 opacity, reset DOM, loop |

### Implementation notes

- The pane content is built in a React component as an array of frames; a single `useEffect` advances the frame index with `requestAnimationFrame` and stops when the tab is hidden (`document.visibilitychange`).
- Typewriter speed: 35 ms per char with ±10 ms jitter for human feel.
- Use `prefers-reduced-motion: reduce` to **skip animation** and render the final frame statically.
- Components live under `apps/landing/src/components/terminal/`:
  - `TerminalWindow.tsx` — chrome
  - `TerminalAnimation.tsx` — driver
  - `frames.ts` — frame timeline data (referenced via i18n keys for comments)

---

## 6. iCloud sync mini-animation (deep-dive A)

- Two SVG laptop silhouettes, ~120 px tall, with a small terminal window inside each.
- Between them: a cloud SVG; CSS `@keyframes` animate two pulse arrows (left↔cloud, right↔cloud) at staggered offsets.
- Inside each laptop, a small dot blinks to indicate "new entry just synced".
- Respects `prefers-reduced-motion`.

## 7. SFTP & Bookmarks mini-animation (deep-dive B)

- Faux terminal window. A "file drawer" panel (SVG + Tailwind) slides in from the left with `transform: translateX(-100% → 0)` on scroll-into-view (Intersection Observer).
- Drawer lists 5 fake remote files (mono-icons, file names, sizes).
- A "bookmark popover" floats above the terminal with 3 host chips (`prod`, `staging`, `bastion`), staggered fade-in.
- Loop on every scroll-into-view; respects `prefers-reduced-motion`.

---

## 8. i18n

### Library

`next-intl` (modern App Router integration).

### Locale strategy

- `defaultLocale: 'en'`, `locales: ['en', 'zh']`.
- Route prefix mode: always-visible (`/en/...`, `/zh/...`).
- Root `/` redirects to user's preferred locale based on cookie (`NEXT_LOCALE`) or `Accept-Language` header, falling back to `en`.
- Language switcher writes the cookie and navigates to the equivalent path in the other locale.

### Files

- `apps/landing/messages/en.json`
- `apps/landing/messages/zh.json`
- `apps/landing/src/i18n/routing.ts` (locales + nav helpers)
- `apps/landing/src/i18n/request.ts` (server-side message loader)

### Translation scope

- All copy: nav, hero, features, deep-dive headings/body, OSS section, footer.
- SEO metadata (title, description, og:image alt) per locale.
- Terminal animation: only the **comment lines** (e.g. `# Connect to your prod server`) and **status toasts** (`iCloud sync · just now`) are translated. Commands themselves (`ssh`, `htop`, `sftp put …`) remain in English.

---

## 9. Accessibility

- Semantic HTML throughout (`<nav>`, `<main>`, `<section>`, `<footer>`, proper heading order).
- All interactive elements keyboard-reachable; visible focus rings (Tailwind `focus-visible:ring-2 ring-cyan-400`).
- Color contrast: every text/background pair tested against WCAG AA on the dark palette.
- Animations respect `prefers-reduced-motion: reduce` — animated terminal renders the final frame; mini-animations render their end state.
- All decorative SVGs marked `aria-hidden="true"`; meaningful ones have `<title>`.
- Language switcher uses a real `<button>` and announces the language in `lang=` on `<html>`.

---

## 10. Performance budget

- LCP < 2.0 s on Vercel cold cache (the hero is HTML+CSS — no images).
- No `<img>` tags except SVG logos; no third-party font files (system font stack on macOS + `font-sans` Tailwind default).
- Terminal animation: < 16 ms per frame (CSS-driven, JS only schedules state transitions).
- Total JS shipped to the browser for the landing route: < 80 kB (gzipped). Use server components by default; mark only `TerminalAnimation`, `LangSwitcher`, scroll-triggered components as `'use client'`.

---

## 11. Out of scope

- Light theme.
- Real GitHub star count fetch (placeholder for now; a follow-up plan can wire it).
- Real Download URL (uses `#download` anchor placeholder).
- Blog, docs, changelog pages.
- Analytics, cookie banner.
- Production SEO image assets (og:image) — a generated placeholder is fine.

---

## 12. File layout (target)

```
apps/landing/
├── package.json
├── next.config.mjs
├── tsconfig.json
├── postcss.config.mjs
├── biome.json (extends repo root if needed)
├── README.md
├── messages/
│   ├── en.json
│   └── zh.json
└── src/
    ├── app/
    │   ├── [locale]/
    │   │   ├── layout.tsx        ← <html class="dark" lang={locale}>
    │   │   ├── page.tsx          ← composes all sections
    │   │   └── not-found.tsx
    │   ├── globals.css           ← Tailwind v4 imports + token vars
    │   └── favicon.ico
    ├── components/
    │   ├── nav/
    │   │   ├── TopNav.tsx
    │   │   └── LangSwitcher.tsx  ('use client')
    │   ├── hero/
    │   │   └── Hero.tsx
    │   ├── terminal/
    │   │   ├── TerminalWindow.tsx
    │   │   ├── TerminalAnimation.tsx  ('use client')
    │   │   └── frames.ts
    │   ├── features/
    │   │   ├── FeatureGrid.tsx
    │   │   └── FeatureCard.tsx
    │   ├── sections/
    │   │   ├── SyncDeepDive.tsx
    │   │   ├── SyncAnimation.tsx       ('use client')
    │   │   ├── SftpDeepDive.tsx
    │   │   ├── SftpAnimation.tsx       ('use client')
    │   │   ├── CapabilityStrip.tsx
    │   │   └── OpenSource.tsx
    │   ├── footer/
    │   │   └── Footer.tsx
    │   └── icons/                ← inline SVG monoline icons
    │       └── *.tsx
    ├── i18n/
    │   ├── routing.ts
    │   └── request.ts
    └── lib/
        └── cn.ts                 ← tiny clsx-style helper
```

---

## 13. Acceptance criteria

1. `bun install` from repo root succeeds with `apps/landing` included.
2. `bun run --filter landing dev` starts on port 3003.
3. Visiting `http://localhost:3003/` redirects to `/en` (or `/zh` if cookie/header indicates).
4. `http://localhost:3003/en` and `http://localhost:3003/zh` both render the full page with no console errors.
5. Language switcher in the nav toggles between locales and preserves scroll position to the same anchor (best-effort).
6. Hero terminal animation autoloops and respects `prefers-reduced-motion`.
7. iCloud sync and SFTP mini-animations play on scroll-into-view.
8. Lighthouse desktop scores ≥ 95 for Performance, Accessibility, Best Practices on the `/en` route.
9. `bun x ultracite check` reports zero issues in `apps/landing`.
10. `bun run check-types` passes across the whole monorepo, including the new app.
11. Page is fully usable with keyboard alone; visible focus rings on every focusable element.
