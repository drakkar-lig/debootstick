#!/bin/sh
set -e
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh
. /dbstck.conf      # get LVM_VG

# find device currently being booted
device=$(get_booted_device $LVM_VG)

echo "** Extending disk space..."

{
    # occupy available space
    if partx_update_exists
    then
        # we can extend the lvm partition and
        # dynamically notify the kernel about it.
        echo MSG resizing partition...
        sgdisk -e -d 3 -n 3:0:0 -t 3:8e00 ${device}
        partx -u ${device}  # notify the kernel
        echo MSG resizing lvm physical volume...
        pvresize ${device}3
    else
        # this OS version is too old to be able
        # to notify the kernel of a partition
        # size update (at least in this case
        # where the partition is in use).
        # instead, we create one more new partition
        # and add it to the lvm group.
        echo MSG creating a new partition...
        sgdisk -e -n 4:0:0 -t 4:8e00 ${device}
        partx -a 4 ${device}  # notify the kernel
        echo MSG creating an lvm physical volume...
        pvcreate ${device}4
        echo MSG extending the lvm volume group...
        vgextend $LVM_VG ${device}4
    fi
    echo MSG resizing lvm logical volume...
    lvextend -l+100%FREE /dev/$LVM_VG/ROOT
    echo MSG resizing filesystem...
    resize2fs /dev/$LVM_VG/ROOT

    echo RETURN 0
} | filter_quiet

echo "** Done."

