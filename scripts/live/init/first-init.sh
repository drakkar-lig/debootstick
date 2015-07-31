#!/bin/sh
set -e
INIT_SCRIPTS_DIR=/opt/debootstick/live/init
. /dbstck.conf                  # for SYSTEM_TYPE
. $INIT_SCRIPTS_DIR/tools.sh    # for fallback_sh()

# if error, run a shell
trap '[ "$?" -eq 0 ] || fallback_sh' EXIT

# remount / read-write
mount -o remount,rw /

# lvm may need this directory to run properly
mkdir -p /run/lock

# run initialization script
if [ "$SYSTEM_TYPE" = "installer" ]
then
    $INIT_SCRIPTS_DIR/migrate-to-disk.sh
else    # 'live' mode
    $INIT_SCRIPTS_DIR/occupy-space.sh
fi

# restore and start the usual init
rm /sbin/init
mv /sbin/init.orig /sbin/init
exec /sbin/init $*

