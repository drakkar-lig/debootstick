#!/bin/bash
# bash is needed for proper handling of password prompt.
set -e
INIT_SCRIPTS_DIR=/opt/debootstick/live/init
. /dbstck.conf                  # for config values
. $INIT_SCRIPTS_DIR/tools.sh    # for functions

# if error, run a shell
trap '[ "$?" -eq 0 ] || fallback_sh' EXIT

# this script is now called at the end of the OS bootup procedure,
# (getty hook), no need to mount/umount filesystems

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

if [ -n "$FIRST_BOOT_SCRIPT" ]
then
    $FIRST_BOOT_SCRIPT
fi
