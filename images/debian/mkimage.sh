#!/bin/bash

set -e

VARIANT=minbase
SUITE=wheezy
TARGET="$PWD/rootfs"
MIRROR=http://ftp.hu.debian.org/debian

sudo debootstrap --variant=$VARIANT $SUITE "$TARGET" $MIRROR
sudo find "$TARGET"/var/cache/apt/archives -type f -name '*.deb' -delete
sudo find "$TARGET"/var/lib/apt/lists -type f -delete

echo "Now execute something like:"
echo
echo "sudo tar -C $TARGET -c . | docker import - cellux/debian:$SUITE-$(uname -m)"
