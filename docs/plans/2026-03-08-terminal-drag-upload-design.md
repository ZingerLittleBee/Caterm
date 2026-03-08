# Terminal Drag & Drop File Upload Design

## Overview

Support dragging files/folders from the OS into the terminal area to upload them to the remote server's current working directory via SFTP, with a floating progress bar at the bottom of the terminal.

## Architecture

### 1. CWD Tracking — OSC 7 Parser Hook

- Register OSC 7 handler via `terminal.parser.registerOscHandler(7, callback)` in xterm.js
- Parse `file://hostname/path` format, extract and store CWD
- CWD state stored in SSH session context
- **Fallback**: If no OSC 7 data available, show a file-browser-style directory picker for user to select target path

### 2. Drag & Drop Handling

- Terminal component listens to `dragover` / `dragleave` / `drop` events
- On drag enter: show semi-transparent overlay with "Release to upload files" prompt
- On drop: read `e.dataTransfer.files` / `e.dataTransfer.items` (for folder support)
- Supports both files and folders (recursive directory upload)

### 3. SFTP Session Management

- On drop, check if a matching SFTP session exists for the current SSH session
- If not, automatically create one using the same SSH credentials (transparent to user)

### 4. Upload Execution

- Reuse existing SFTP transfer queue mechanism (`sftp-transfer-progress` events, concurrency limit of 3)
- For folders: recursively traverse, create directory structure first, then upload files
- Upload target: CWD from OSC 7, or user-selected path from fallback picker

### 5. Progress UI — Floating Progress Bar

- Semi-transparent floating component at the bottom of terminal area
- Shows: filename, progress percentage, transfer speed
- Multiple files: collapsible list view
- Auto-dismiss after completion (with short delay)
- Support canceling individual transfers

## Data Flow

```
OS file drag → Terminal drop event
  → Get CWD (OSC 7 cache / fallback directory picker)
  → Check/auto-create SFTP session
  → Traverse files (recursive for folders)
  → Call existing SFTP upload interface
  → Listen to sftp-transfer-progress events
  → Update floating progress bar at terminal bottom
```

## Files to Modify

| File | Change |
|------|--------|
| `ssh-terminal.tsx` | Add OSC 7 handler, drag/drop events, overlay UI |
| `ssh-session-provider.tsx` | Extend session state with `cwd` field |
| `sftp-provider.tsx` | Add auto-create SFTP session logic |
| New: terminal upload progress component | Floating progress bar UI |
| New: terminal drag overlay component | Drag visual feedback |
| New: directory picker component | Fallback directory selection dialog |
