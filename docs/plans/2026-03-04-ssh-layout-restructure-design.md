# SSH Page Layout Restructure Design

## Goal

Restructure the SSH page (`/ssh`) to use the same `SidebarProvider + AppSidebar + SidebarInset` layout as the index page (`/`), replacing the current custom sidebar layout.

## Current State

The SSH page uses a custom layout:
- Left: `HostList` in a `w-64 border-r` div
- Right: `SshTabBar` + terminal area + `SshStatusBar`
- No `AppSidebar`, no `SiteHeader`, requires `row-span-full` hack for full-height

## Target Layout

```
SshSessionProvider
└── SidebarProvider
    ├── AppSidebar variant="inset"
    │   └── children: <HostList />
    └── SidebarInset
        ├── SiteHeader title="SSH Terminal"
        ├── SshTabBar
        ├── Terminal Area (flex-1)
        └── SshStatusBar
```

## Component Changes

### 1. `AppSidebar` (`src/components/app-sidebar.tsx`)

- Accept `children?: ReactNode` prop
- Render children inside `SidebarContent` after `NavMain`
- Existing behavior unchanged when no children provided

### 2. `SiteHeader` (`src/components/site-header.tsx`)

- Accept `title?: string` prop (default: "Documents")
- Replace hardcoded `<h1>Documents</h1>` with `<h1>{title}</h1>`

### 3. `ssh/route.tsx` (`src/routes/ssh/route.tsx`)

- Wrap with `SidebarProvider` + `AppSidebar` + `SidebarInset`
- Pass `HostList` as children to `AppSidebar`
- Place `SiteHeader` (title="SSH Terminal"), `SshTabBar`, terminal area, `SshStatusBar` inside `SidebarInset`
- Remove `row-span-full` hack and custom `w-64 border-r` sidebar div
- All existing logic (connect, disconnect, form, settings loading) remains unchanged

### 4. `HostList` style adaptation

- Verify HostList renders correctly within sidebar width constraints
- Adjust styling if needed to fit sidebar scroll behavior

## Not In Scope

- No changes to SSH business logic (connect/disconnect/sessions)
- No changes to `SshTabBar`, `SshTerminal`, `SshStatusBar`, `ConnectDialog`, `HostForm`
- No changes to `ssh/settings.tsx` (already uses the target layout pattern)
