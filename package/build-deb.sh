#!/usr/bin/env bash
# Build lxc-runner-tools_<version>_all.deb into dist/
# Usage: package/build-deb.sh [VERSION]   (default: git tag, e.g. v1.0.0 → 1.0.0)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/package"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
# Debian versions must start with a digit (untagged builds: 0.0.0+<sha>)
[[ "$VERSION" =~ ^[0-9] ]] || VERSION="0.0.0+${VERSION}"

NAME="lxc-runner-tools_${VERSION}_all"
STAGE="$ROOT/dist/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/sbin" "$STAGE/usr/lib/lxc-runner" \
    "$STAGE/etc/lxc-runner" "$STAGE/lib/systemd/system"

sed "s/@VERSION@/${VERSION}/" "$PKG/debian/control" > "$STAGE/DEBIAN/control"
cp "$PKG/debian/conffiles" "$STAGE/DEBIAN/"
install -m 755 "$PKG/debian/postinst" "$PKG/debian/prerm" "$PKG/debian/postrm" "$STAGE/DEBIAN/"

sed "s/@VERSION@/${VERSION}/" "$PKG/lxc-runner" > "$STAGE/usr/sbin/lxc-runner"
chmod 755 "$STAGE/usr/sbin/lxc-runner"

install -m 644 "$PKG/lib/common.sh" "$STAGE/usr/lib/lxc-runner/common.sh"
install -m 755 "$PKG/lib/recycle.sh" "$STAGE/usr/lib/lxc-runner/recycle.sh"
install -m 755 "$ROOT/lxc_create_github_actions_runner.master.sh" "$STAGE/usr/lib/lxc-runner/master.sh"
install -m 755 "$ROOT/lxc_create_github_actions_runner.clone.sh" "$STAGE/usr/lib/lxc-runner/clone.sh"

install -m 600 "$PKG/lxc-runner.env" "$STAGE/etc/lxc-runner/lxc-runner.env"
install -m 644 "$PKG/systemd/lxc-runner-recycle.service" "$PKG/systemd/lxc-runner-recycle.timer" \
    "$STAGE/lib/systemd/system/"

dpkg-deb --build --root-owner-group "$STAGE" "$ROOT/dist/${NAME}.deb"
rm -rf "$STAGE"
echo "Built dist/${NAME}.deb"
