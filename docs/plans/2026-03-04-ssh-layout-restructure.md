# SSH Layout Restructure Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Restructure the SSH page to use the same `SidebarProvider + AppSidebar + SidebarInset + SiteHeader` layout as the index page, with HostList injected into AppSidebar via children.

**Architecture:** The SSH route currently uses a custom two-panel layout (HostList sidebar + terminal area). We replace this with the shared layout system: `SidebarProvider` wraps `AppSidebar` (with HostList as children) and `SidebarInset` (containing SiteHeader, SshTabBar, terminal area, SshStatusBar). This gives the SSH page collapsible sidebar, consistent navigation, and uniform look.

**Tech Stack:** React 19, TanStack Router, shadcn/ui Sidebar, TailwindCSS v4

---

### Task 1: Make SiteHeader accept a dynamic title

**Files:**
- Modify: `apps/web/src/components/site-header.tsx`

**Step 1: Update SiteHeader to accept title prop**

Replace the entire file content:

```tsx
import { Separator } from "@/components/ui/separator";
import { SidebarTrigger } from "@/components/ui/sidebar";

interface SiteHeaderProps {
	title?: string;
}

export function SiteHeader({ title = "Documents" }: SiteHeaderProps) {
	return (
		<header className="flex h-(--header-height) shrink-0 items-center gap-2 border-b transition-[width,height] ease-linear group-has-data-[collapsible=icon]/sidebar-wrapper:h-(--header-height)">
			<div className="flex w-full items-center gap-1 px-4 lg:gap-2 lg:px-6">
				<SidebarTrigger className="-ml-1" />
				<Separator
					className="mx-2 h-4 data-vertical:self-auto"
					orientation="vertical"
				/>
				<h1 className="font-medium text-base">{title}</h1>
			</div>
		</header>
	);
}
```

**Step 2: Verify index page still works**

Run: `cd apps/web && bun run build`
Expected: Build succeeds with no errors. The index page passes "Documents" implicitly via default prop.

**Step 3: Commit**

```bash
git add apps/web/src/components/site-header.tsx
git commit -m "refactor(site-header): accept dynamic title prop"
```

---

### Task 2: Make AppSidebar accept children

**Files:**
- Modify: `apps/web/src/components/app-sidebar.tsx`

**Step 1: Add children prop and render it in SidebarContent**

In `app-sidebar.tsx`, change the function signature and body:

```tsx
// Change the export function signature from:
export function AppSidebar({ ...props }: React.ComponentProps<typeof Sidebar>) {

// To:
export function AppSidebar({
	children,
	...props
}: React.ComponentProps<typeof Sidebar>) {
```

Then in the JSX, add children rendering inside `SidebarContent`, between `NavDocuments` and `NavSecondary`:

```tsx
<SidebarContent>
	<NavMain items={data.navMain} />
	<NavDocuments items={data.documents} />
	{children}
	<NavSecondary className="mt-auto" items={data.navSecondary} />
</SidebarContent>
```

**Step 2: Verify index page still works**

Run: `cd apps/web && bun run build`
Expected: Build succeeds. Index page renders identically (no children passed).

**Step 3: Commit**

```bash
git add apps/web/src/components/app-sidebar.tsx
git commit -m "refactor(app-sidebar): accept children slot in SidebarContent"
```

---

### Task 3: Restructure SSH route layout

**Files:**
- Modify: `apps/web/src/routes/ssh/route.tsx`

**Step 1: Rewrite the SshLayout return JSX**

Replace the `return (...)` block in `SshLayout` function (lines 238-317) with:

```tsx
return (
	<SidebarProvider
		style={
			{
				"--sidebar-width": "calc(var(--spacing) * 72)",
				"--header-height": "calc(var(--spacing) * 12)",
			} as React.CSSProperties
		}
	>
		<AppSidebar variant="inset">
			<HostList
				key={refreshKey}
				onConnect={handleConnectRequest}
				onEdit={handleEditHost}
				onNewHost={handleNewHost}
			/>
		</AppSidebar>
		<SidebarInset>
			<SiteHeader title="SSH Terminal" />

			<SshTabBar
				activeSessionId={activeSessionId}
				onAddSession={handleNewHost}
				onCloseSession={disconnect}
				onSelectSession={setActive}
				sessions={sessions}
			/>

			{/* Terminal area */}
			<div className="relative flex-1">
				{sessions.size === 0 ? (
					<div className="flex h-full items-center justify-center text-muted-foreground">
						<p>Select a host to connect or add a new one.</p>
					</div>
				) : (
					Array.from(sessions.values()).map((session) => (
						<SshTerminal
							cursorBlink={terminalSettings.cursorBlink}
							cursorStyle={terminalSettings.cursorStyle}
							fontFamily={terminalSettings.fontFamily}
							fontSize={terminalSettings.fontSize}
							isActive={session.id === activeSessionId}
							key={session.id}
							scrollback={terminalSettings.scrollback}
							sessionId={session.id}
						/>
					))
				)}
			</div>

			<SshStatusBar session={activeSession} />
		</SidebarInset>

		{/* Connect credentials dialog */}
		<ConnectDialog
			host={connectTarget}
			onCancel={handleConnectCancel}
			onConnect={handleConnectConfirm}
			open={connectTarget !== null}
		/>

		{/* Host form sheet */}
		<Sheet
			onOpenChange={(isOpen) => !isOpen && handleFormCancel()}
			open={formOpen}
		>
			<SheetContent>
				<SheetHeader>
					<SheetTitle>{editingHost ? "Edit Host" : "New Host"}</SheetTitle>
					<SheetDescription>
						{editingHost
							? "Update the SSH host connection details."
							: "Add a new SSH host to connect to."}
					</SheetDescription>
				</SheetHeader>
				<div className="p-4">
					<HostForm
						host={editingHost}
						onCancel={handleFormCancel}
						onSubmit={handleFormSubmit}
					/>
				</div>
			</SheetContent>
		</Sheet>
	</SidebarProvider>
);
```

**Step 2: Update imports**

Add these imports to the top of `ssh/route.tsx`:

```tsx
import { AppSidebar } from "@/components/app-sidebar";
import { SiteHeader } from "@/components/site-header";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
```

Remove unused imports if the `HostList` import path stays the same (it should — `@/components/hosts/host-list`).

**Step 3: Verify build**

Run: `cd apps/web && bun run build`
Expected: Build succeeds with no errors.

**Step 4: Lint and format**

Run: `bun x ultracite fix`
Expected: No remaining issues.

**Step 5: Commit**

```bash
git add apps/web/src/routes/ssh/route.tsx
git commit -m "refactor(ssh): restructure layout to use AppSidebar + SidebarInset"
```

---

### Task 4: Adapt HostList styling for sidebar context

**Files:**
- Modify: `apps/web/src/components/hosts/host-list.tsx` (if needed)

**Step 1: Visual check**

Run the dev server: `cd apps/web && bun run dev` (or `make` from root)
Open `/ssh` in the browser.

Check:
- HostList renders inside the sidebar without overflow
- HostCards fit within the sidebar width
- Scrolling works within the sidebar
- "Add host" button is accessible
- Sidebar collapse/expand works (keyboard shortcut `b`)

**Step 2: Remove the hardcoded border-b header if it clashes with sidebar chrome**

The current HostList has its own header with `border-b`. Inside the sidebar, this may look redundant since the sidebar has its own header area. If it looks fine, skip this step. If it clashes, remove the header div and move the "Add host" button elsewhere.

**Step 3: Commit any style fixes**

```bash
git add apps/web/src/components/hosts/host-list.tsx
git commit -m "style(host-list): adapt styling for sidebar context"
```

If no changes were needed, skip this commit.

---

### Task 5: Final verification and lint

**Step 1: Full build check**

Run: `cd apps/web && bun run build`
Expected: Clean build, no errors.

**Step 2: Lint check**

Run: `bun x ultracite check`
Expected: No issues.

**Step 3: Manual verification checklist**

- [ ] `/` index page: AppSidebar + SiteHeader renders correctly, title says "Documents"
- [ ] `/ssh` page: AppSidebar (with HostList) + SiteHeader ("SSH Terminal") + SshTabBar + terminal area
- [ ] `/ssh/settings` page: unchanged, still works
- [ ] Sidebar collapse/expand works on all pages
- [ ] SSH connect/disconnect flow works as before
- [ ] Host add/edit/delete flows work as before
