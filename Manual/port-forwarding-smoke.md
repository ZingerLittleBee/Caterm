# Port Forwarding — Manual Smoke

End-to-end checklist for verifying per-host port forwarding. Run on a two-Mac setup (Device A configures, Device B verifies sync) before merging.

## Prep

- A reachable test host (e.g., a Linux VM or remote box where you can `nc -l` to verify the forward landed).
- On the test host, install `nc` and ensure firewall allows the forward target ports.

## Cases

- [ ] **Local forward (happy path)**
  Add host. Add `L 8080 → localhost:8080`. Connect. On the test host, run `nc -l -p 8080`. On the Mac, `nc localhost 8080` and type — verify text appears on the test host.

- [ ] **Required forward, port pre-occupied**
  On the Mac, run `nc -l 5432` (binds 5432). In Caterm, add host with one required `L 5432 → db:5432`. Connect → expect red FailureOverlay reading "Port 5432 ... is already in use on your Mac. Edit the host..."

- [ ] **Optional forward, port pre-occupied**
  Same setup as previous, but mark the forward optional. Connect → terminal opens normally, yellow Banner appears reading "Skipped optional port forward(s): local 5432 (alreadyInUse)".

- [ ] **Dynamic SOCKS forward**
  Add `D 1080`. Connect. Run `curl --socks5 localhost:1080 https://api.ipify.org` — expect to see the remote host's public IP (not the Mac's).

- [ ] **Chain — only target's forwards bind locally**
  Add jumpbox host (with one Local forward configured, e.g., `L 9090 → localhost:9090`). Add target host using jumpbox as Via host, with its own `L 8080 → localhost:8080`. Connect to target. On Mac, `nc -l 9090` should be free (jumpbox's forward not active); `nc localhost 8080` should reach the target.

- [ ] **Remote forward (`-R`)**
  Add `R 9090 → localhost:9090`. Connect. On the test host, run `nc localhost 9090` — verify it reaches the Mac side.

- [ ] **Edit / save / reconnect persists**
  Edit an existing host, add a new forward, save. Reconnect — verify the new forward binds.

- [ ] **CloudKit sync**
  Edit forwards on Device A. Wait ≤ 30 s. Pull on Device B (or wait for push subscription). Verify Device B sees the new forwards in the host form.

- [ ] **ControlMaster teardown**
  Connect host with a Local forward (e.g., 8080). Confirm `lsof -iTCP:8080 -sTCP:LISTEN` shows the ssh process. Close the tab. Immediately re-run `lsof` — expect no listener. (Compare to a host without forwards: closing leaves the master alive for ~30 s.)
