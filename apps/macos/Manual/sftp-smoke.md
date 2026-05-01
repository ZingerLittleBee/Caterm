# SFTP / File Drawer manual smoke

Run before tagging any release that touches `FileTransferStore`,
`SFTPCommandBuilder`, or `FileDrawerView`.

Prereq: a reachable SSH host with sftp-server enabled.

## 1. List home directory
- Connect to host, press ⌘⇧F → drawer opens, lists `~`.

## 2. Navigate via breadcrumb
- Double-click a directory → drawer lists it; breadcrumb updates.

## 3. Upload single file via drag-to-drawer
- Drag a small file from Finder onto drawer → file appears in remote list after upload.

## 4. Upload directory tree
- Drag a directory from Finder → drawer enqueues with `-R` (verify
  via remote `ls -la <dir>`); takes longer; queue updates on completion.

## 5. Download single file via drag-to-Finder
- Drag a file from drawer to Finder window → file appears locally.

## 6. Drag file to terminal — pastes path (unchanged)
- Drag a file to terminal area without ⌥ → shell-quoted path pasted at cursor.

## 7. ⌥ + drag file to terminal — uploads
- Hold ⌥, drag a file into terminal → "Upload to remote directory" sheet appears
  prefilled with the drawer's current path; click OK → file uploads.

## 8. ⌥ + drag with no OSC 7 — modal sheet appears
- Same as #7; current v1 always shows the sheet (OSC 7 path is v2).

## 9. Rename file
- Right-click file → Rename → enter new name → file renames on remote.

## 10. Delete file/directory
- Right-click → Delete → file removed; refresh confirms.

## 11. mkdir
- `+` button → enter name → folder appears.

## 12. Copy remote path
- Right-click → Copy Path → paste into terminal; matches expected path.

## 13. Cancel mid-upload
- Drag a large file (≥100 MB), cancel via ✕ before completion → task → cancelled.
  Partial file may remain on remote (acceptable v1).

## 14. ControlMaster expires
- After ControlPersist=10m timeout (or `ssh -O exit -S <socket> user@host`
  manually), trigger any drawer action → "Reconnect host to browse files"
  banner appears.

## 15. Path with spaces and unicode
- Upload `"测试 文件.txt"` → roundtrips back via download with same name.
