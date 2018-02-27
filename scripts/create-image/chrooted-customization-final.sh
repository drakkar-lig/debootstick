#!/bin/sh
loop_device=$1

eval "$chrooted_functions"
start_failsafe_mode

# in the chroot commands should use /tmp for temporary files
export TMPDIR=/tmp
export DEBIAN_FRONTEND=noninteractive LANG=C

# classical mounts
failsafe mount -t proc none /proc
failsafe_mount_sys_and_dev

if $arch_prepare_rootfs_exists
then
    arch_prepare_rootfs final inside
fi

echo -n "I: final image - setting up the bootloader... "
arch_install_bootloader
echo done

if $arch_cleanup_rootfs_exists
then
    arch_cleanup_rootfs final inside
fi

# umount things
undo_all

