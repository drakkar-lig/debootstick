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
    rootfs_partnum=$(get_pv_part_num $device)
else
    rootfs_device=$(findmnt -no SOURCE /)
    device=$(part_to_disk $rootfs_device)
    rootfs_partnum=$(get_part_num $rootfs_device)
fi
rootfs_partition="$device$rootfs_partnum"

echo "** Extending disk space..."

{
    echo MSG resizing partition...
    sgdisk -e -d $rootfs_partnum -n $rootfs_partnum:0:0 \
                -t $rootfs_partnum:8e00 ${device}
    partx -u ${device}  # notify the kernel
    if $USE_LVM
    then
        echo MSG resizing lvm physical volume...
        pvresize $rootfs_partition

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

