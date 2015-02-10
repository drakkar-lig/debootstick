#!/bin/sh
loop_device=$1

eval "$chrooted_functions"
start_failsafe_mode

# in the chroot commands should use /tmp for temporary files
export TMPDIR=/tmp

# classical mounts
failsafe mount -t proc none /proc
failsafe_mount_sys_and_dev

echo -n "I: final image - setting up the bootloader... "
# let grub find our virtual device
cd /boot/grub
cat > device.map << END_MAP
(hd0) $loop_device
END_MAP

# install
quiet_grub_install $loop_device

# remove previous file
rm /boot/grub/device.map
echo done

# umount things
undo_all

