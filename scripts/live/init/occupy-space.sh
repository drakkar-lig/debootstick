#!/bin/sh
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh
. /dbstck.conf      # get LVM_VG

# find device currently being booted
if $USE_LVM
then
    LVM_VG=$(get_vg_name $STICK_OS_ID)
    rootfs_device="/dev/$LVM_VG/ROOT"
    device=$(get_booted_device_from_vg $LVM_VG)
else
    rootfs_device=$(findmnt -no SOURCE /)
    device=$(part_to_disk $rootfs_device)
fi

echo "** Extending disk space..."

{
    echo MSG resizing partition...
    expand_last_partition ${device}

    if $USE_LVM
    then
        pv_partnum=$(get_pv_part_num $device)
        pv_partition="$(get_part_device $device $pv_partnum)"

        echo MSG resizing lvm physical volume...
        pvresize $pv_partition

        if $(vg_has_free_space $LVM_VG)
        then
           echo MSG resizing lvm logical volume...
           lvextend -l+100%FREE $rootfs_device
        fi
    fi

    echo MSG resizing filesystem...
    resize2fs $rootfs_device

    echo RETURN 0
} | filter_quiet

echo "** Done."

