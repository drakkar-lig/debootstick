#!/bin/sh
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh
. /dbstck.conf      # get LVM_VG

# find device currently being booted
device=$(get_booted_device $LVM_VG)

pv_part_num=$(get_pv_part_num $device)
next_part_num=$(get_next_part_num $device)

echo "** Extending disk space..."

{
    # occupy available space
    if partx_update_exists
    then
        # we can extend the lvm partition and
        # dynamically notify the kernel about it.
        echo MSG resizing partition...
        sgdisk -e -d $pv_part_num -n $pv_part_num:0:0 \
                    -t $pv_part_num:8e00 ${device}
        partx -u ${device}  # notify the kernel
        echo MSG resizing lvm physical volume...
        pvresize ${device}$pv_part_num
    else
        # this OS version is too old to be able
        # to notify the kernel of a partition
        # size update (at least in this case
        # where the partition is in use).
        # instead, we create one more new partition
        # and add it to the lvm group.
        echo MSG creating a new partition...
        sgdisk -e -n $next_part_num:0:0 \
                    -t $next_part_num:8e00 ${device}
        partx -a $next_part_num ${device}  # notify the kernel
        echo MSG creating an lvm physical volume...
        pvcreate ${device}$next_part_num
        echo MSG extending the lvm volume group...
        vgextend $LVM_VG ${device}$next_part_num
    fi

    if [ "x$(vgs -o vg_free --noheadings --nosuffix $LVM_VG \
                | tr -d [:blank:])" != "x0" ]; then
       echo MSG resizing lvm logical volume...
       lvextend -l+100%FREE /dev/$LVM_VG/ROOT
       echo MSG resizing filesystem...
       resize2fs /dev/$LVM_VG/ROOT
    fi

    echo RETURN 0
} | filter_quiet

echo "** Done."

