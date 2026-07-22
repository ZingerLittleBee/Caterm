# Workspace owns layout; SessionStore owns connection lifecycle

Status: accepted

A native window tab represents a Workspace, whose platform-neutral model owns
pane topology, presentation, focus, templates, and command-broadcast scope.
SessionStore continues to own each terminal session's host, authentication,
connection state, reconnect policy, history, and terminal-surface generation.
We rejected both adding recursive pane state to SessionStore.Tab and copying
Termius's custom tab chrome: the former couples UI geometry to SSH lifecycle,
while the latter discards macOS window restoration, responder routing, and
native tab behavior.

Consequences: Focus and Split are projections of the same live pane tree;
hidden panes remain connected; pane and workspace closure are explicit domain
actions rather than generic view-disappearance effects; saved templates restore
declarations as fresh sessions and never claim to resume a live PTY.
