#!/bin/bash
# bash is needed for proper handling of password prompt.
set -e
INIT_SCRIPTS_DIR=/opt/debootstick/live/init
. /dbstck.conf                  # for config values
. $INIT_SCRIPTS_DIR/tools.sh    # for functions

# if error, run a shell
trap '[ "$?" -eq 0 ] || fallback_sh' EXIT

# we will need /proc and /sys
[ -e /proc/self ] || mount_proc=1
[ -e /sys/class ] || mount_sys=1
[ "$mount_proc" = "1" ] && mount -t proc none /proc
[ "$mount_sys" = "1" ] && mount -t sysfs none /sys

# remount / read-write
mount -o remount,rw /

# lvm may need this directory to run properly
mkdir -p /run/lock

# ask and set the root password if needed
if [ "$ASK_ROOT_PASSWORD_ON_FIRST_BOOT" = "1" ]
then
    ask_and_set_pass
fi

# run initialization script
if [ "$SYSTEM_TYPE" = "installer" ]
then
    $INIT_SCRIPTS_DIR/migrate-to-disk.sh
else    # 'live' mode
    $INIT_SCRIPTS_DIR/occupy-space.sh
fi

# restore the lvm config as it was in the
# initial chroot environment
restore_lvm_conf

# cleanup
[ "$mount_proc" = "1" ] && umount /proc
[ "$mount_sys" = "1" ] && umount /sys

# restore and start the usual init
rm /sbin/init
mv /sbin/init.orig /sbin/init
exec /sbin/init $*

