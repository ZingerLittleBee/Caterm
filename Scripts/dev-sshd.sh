#!/bin/bash
# Throwaway REAL OpenSSH server for the mobile SSH terminal e2e.
#
# Runs upstream OpenSSH (linuxserver/openssh-server) in Docker and
# publishes it on 127.0.0.1:2222. The iOS Simulator shares the host
# loopback, so the app connects to 127.0.0.1:2222 directly.
#
# PASSWORD auth only: NIOSSHTransport (swift-nio-ssh 0.13.0) implements
# password auth but not OpenSSH private-key auth, so the e2e host must
# use a password credential. Password auth against a *real* macOS account
# would need root/PAM; a containerized sshd gives a genuine OpenSSH server
# with a known password and no host privileges.
#
# Ctrl-C (or any exit) stops and removes the container.
set -euo pipefail

NAME="caterm-e2e-sshd"
USER_NAME="caterm"
USER_PASSWORD="caterm-e2e"
PORT="2223"
IMAGE="linuxserver/openssh-server:latest"

cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	echo "removed container $NAME"
}
trap cleanup EXIT INT TERM

docker rm -f "$NAME" >/dev/null 2>&1 || true

echo "pulling $IMAGE..."
docker pull "$IMAGE" >/dev/null

docker run -d --name "$NAME" \
	-e PUID=1000 -e PGID=1000 -e TZ=Etc/UTC \
	-e PASSWORD_ACCESS=true \
	-e USER_NAME="$USER_NAME" \
	-e USER_PASSWORD="$USER_PASSWORD" \
	-e SUDO_ACCESS=false \
	-p 127.0.0.1:"$PORT":2222 \
	"$IMAGE" >/dev/null

echo "waiting for sshd..."
for _ in $(seq 1 30); do
	if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
		break
	fi
	sleep 1
done
nc -z 127.0.0.1 "$PORT" 2>/dev/null || { echo "sshd did not come up"; docker logs "$NAME"; exit 1; }

cat <<EOF

real OpenSSH server is up.
  endpoint for simulator: 127.0.0.1:$PORT  (simulator shares host loopback)
  username: $USER_NAME
  password: $USER_PASSWORD
  credential kind: password

verify from this Mac:
  ssh -p $PORT -o StrictHostKeyChecking=no $USER_NAME@127.0.0.1 'echo HARNESS_OK'
  (password: $USER_PASSWORD)

streaming container logs; Ctrl-C to stop and tear down.
EOF

docker logs -f "$NAME"
