#!/bin/sh
set -eu
apk add --no-cache build-base bash bc bison flex perl python3 openssl-dev elfutils-dev linux-headers curl xz coreutils
cd /kernel
version=6.18.5
if [ ! -f "linux-$version.tar.xz" ]; then
  curl -fL --retry 3 "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$version.tar.xz" -o "linux-$version.tar.xz.part"
  mv "linux-$version.tar.xz.part" "linux-$version.tar.xz"
fi
curl -fsSL https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc -o sha256sums.asc
grep " linux-$version.tar.xz$" sha256sums.asc > source.sha256
sha256sum -c source.sha256
if [ ! -f config-arm64 ]; then
  curl -fL --retry 3 https://raw.githubusercontent.com/apple/containerization/main/kernel/config-arm64 -o config-arm64
fi
sha256sum config-arm64 > config.sha256
mkdir -p /kbuild
tar -xf "linux-$version.tar.xz" -C /kbuild --strip-components=1
cd /kbuild
cp /kernel/config-arm64 .config
scripts/config --enable WIREGUARD --enable TUN --set-str LOCALVERSION '-wg-testbed'
make ARCH=arm64 olddefconfig
grep -qx 'CONFIG_WIREGUARD=y' .config
make ARCH=arm64 -j8 Image > /kernel/build.log 2>&1
cp .config /kernel/native.config
cp arch/arm64/boot/Image /kernel/vmlinux-native-wireguard
cd /kernel
sha256sum vmlinux-native-wireguard > native.sha256
echo 'Native WireGuard kernel built successfully.'
