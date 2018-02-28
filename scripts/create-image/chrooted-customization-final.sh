#!/bin/sh
loop_device=$1

eval "$chrooted_functions"
probe_target_optional_functions
start_failsafe_mode

# in the chroot commands should use /tmp for temporary files
export TMPDIR=/tmp
export DEBIAN_FRONTEND=noninteractive LANG=C

# classical mounts
failsafe mount -t proc none /proc
failsafe_mount_sys_and_dev

optional_target_prepare_rootfs final inside

echo -n "I: final image - setting up the bootloader... "
target_install_bootloader
echo done

optional_target_cleanup_rootfs final inside

# umount things
undo_all

