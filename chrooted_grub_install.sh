#!/bin/bash
set -x

loop_device=$1

mount -t devtmpfs none /dev
mount -t proc none /proc
mount -t devpts none /dev/pts
mount -t sysfs none /sys

# let grub find our virtual device
cd /boot/grub
cat > device.map << END_MAP
(hd0) $loop_device
END_MAP

# install
grub-install $loop_device
update-grub

# remove previous file
rm /boot/grub/device.map

umount /sys /dev/pts /proc /dev

