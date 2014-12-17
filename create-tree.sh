#!/bin/bash
set -e
# ensure we are root
if [ "$USER" != "root" ]
then
    sudo $0 $*
    exit
fi
TREE_DIR="$1"
DEBUG=1
if [ "$DEBUG" = "1" ]
then
    PACKAGES=$PACKAGES,isc-dhcp-client,vim,squashfs-tools,linux-image-generic,lvm2,busybox-static,gdisk,grub-pc,strace
fi

if [ ! "$PACKAGES" = "" ]
then
    inc_option="--include=$PACKAGES"
fi

rm -rf "$TREE_DIR"
debootstrap --arch=amd64 --variant=minbase $inc_option trusty "$TREE_DIR" http://ch.archive.ubuntu.com/ubuntu/

