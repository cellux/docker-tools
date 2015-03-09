#!/bin/bash

set -e

VARIANT=minbase
SUITE=trusty
TARGET="$PWD/rootfs"
MIRROR=http://archive.ubuntu.com/ubuntu

[ -d "$TARGET" ] && sudo rm -rf "$TARGET"
sudo debootstrap --variant=$VARIANT $SUITE "$TARGET" $MIRROR
sudo find "$TARGET"/var/cache/apt/archives -type f -name '*.deb' -delete
sudo find "$TARGET"/var/lib/apt/lists -type f -delete

sudo /bin/sh -c "cat > $TARGET/etc/apt/sources.list" <<EOT
deb http://archive.ubuntu.com/ubuntu/ trusty main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ trusty-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ trusty-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu trusty-security main restricted universe multiverse
EOT

echo "Now execute something like:"
echo
echo "sudo tar -C $TARGET -c . | docker import - cellux/ubuntu:$SUITE-$(uname -m)"
