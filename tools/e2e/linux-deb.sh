#!/usr/bin/env bash
# Installs Alona's .deb in a fresh Ubuntu 24.04 container and drives it under a
# virtual display with tools/e2e-desktop.mjs. Run on the host:
#
#   bash tools/e2e/linux-deb.sh            (after bun tools/build-desktop.mjs linux)
#   ARCH=amd64 bash tools/e2e/linux-deb.sh
#
# Checks that the package's declared dependencies install with apt, that the
# menu entry's command opens a window titled Alona, then runs the flows.
# Writes docs/media/desktop/linux/, including linux-deb.log. The container has
# no GPU, so the page module picks the demo engine; the run accepts that.
set -euo pipefail

if [ "${1:-}" != inside ]; then
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  ARCH="${ARCH:-arm64}"
  DEB="$(ls "$ROOT"/desktop/out/alona_*_"$ARCH".deb)"
  LOG="$ROOT/desktop/out/linux-deb-$ARCH.log"
  status=0
  # Chromium's sandbox needs to create namespaces, which Docker's default profile refuses.
  docker run --rm --platform "linux/$ARCH" --cap-add SYS_ADMIN --security-opt seccomp=unconfined -v "$ROOT:/repo" -v "$DEB:/tmp/alona.deb:ro" -e ARCH="$ARCH" \
    ubuntu:24.04 bash /repo/tools/e2e/linux-deb.sh inside 2>&1 | tee "$LOG" || status=$?
  MEDIA="$ROOT/docs/media/desktop/linux"
  mkdir -p "$MEDIA"
  cp "$LOG" "$MEDIA/linux-deb.log"
  if [ -f "$MEDIA/e2e.webm" ] && ffmpeg -loglevel error -y -i "$MEDIA/e2e.webm" -vf format=yuv420p -movflags +faststart "$MEDIA/e2e.mp4"; then
    rm "$MEDIA/e2e.webm"
  fi
  exit "$status"
fi

export DEBIAN_FRONTEND=noninteractive
step() { printf '\n== %s\n' "$*"; }

step "the package's declared fields"
dpkg-deb -f /tmp/alona.deb Package Version Architecture Depends Recommends
apt-get update -qq

step "apt installs the package and its dependencies"
apt-get install -y -qq --no-install-recommends /tmp/alona.deb > /tmp/apt.log 2>&1 || { tail -30 /tmp/apt.log; exit 1; }
tail -3 /tmp/apt.log
dpkg -s alona | grep -E '^(Status|Version)'
stat -c '%A %U %n' /opt/Alona/alona /opt/Alona/chrome-sandbox
cat /usr/share/applications/alona.desktop
missing="$(ldd /opt/Alona/alona | grep 'not found' || true)"
if [ -n "$missing" ]; then echo "libraries the package did not bring:"; echo "$missing"; exit 1; fi
echo "ldd: every library of /opt/Alona/alona resolves"

step "test tools: a virtual display, a window lister, Bun"
apt-get install -y -qq --no-install-recommends xvfb xdotool curl unzip ca-certificates procps ffmpeg > /dev/null
BUN_ARCH=$([ "$ARCH" = arm64 ] && echo aarch64 || echo x64)
curl -fsSL -o /tmp/bun.zip "https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-linux-$BUN_ARCH.zip"
unzip -q /tmp/bun.zip -d /opt && mv "/opt/bun-linux-$BUN_ARCH" /opt/bun
useradd -m tester
Xvfb :99 -screen 0 1280x900x24 > /dev/null 2>&1 &
export DISPLAY=:99
sleep 2

step "the menu entry's command opens the Alona window"
EXEC="$(sed -n 's/^Exec=//p' /usr/share/applications/alona.desktop | sed 's/ %U$//')"
echo "Exec: $EXEC"
su tester -c "DISPLAY=:99 $EXEC" > /tmp/menu-launch.log 2>&1 &
if timeout 60 xdotool search --sync --name '^Alona$' > /dev/null; then
  echo "window titled Alona: yes"
else
  echo "window titled Alona: NO"; tail -20 /tmp/menu-launch.log; exit 1
fi
pkill -f /opt/Alona/alona || true
sleep 2

step "the flows, driven by tools/e2e-desktop.mjs"
# Playwright's screencast stalls under software rendering, so the video is a grab of the virtual display.
ffmpeg -loglevel error -y -f x11grab -video_size 1280x900 -framerate 10 -i :99 -pix_fmt yuv420p /tmp/e2e.mp4 &
GRAB=$!
status=0
su tester -c "cd /repo && DISPLAY=:99 /opt/bun/bun tools/e2e-desktop.mjs --exe /opt/Alona/alona --platform linux --allow-demo --no-video" || status=$?
kill -INT "$GRAB"; wait "$GRAB" || true
cp /tmp/e2e.mp4 /repo/docs/media/desktop/linux/e2e.mp4
exit "$status"
