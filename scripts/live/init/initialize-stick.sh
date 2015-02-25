#!/bin/sh
THIS_DIR=$(cd $(dirname $0); pwd)
. $THIS_DIR/tools.sh

# get variables such as LVM_VG
. /dbstck.conf

# lvm may need this directory to run properly
mkdir -p /run/lock

# find device currently being booted
set -- $(pvs | grep $LVM_VG)
device=$(echo $1 | sed -e "s/.$//")

# occupy available space
echo "Extending disk space..."
if partx_update_exists
then
    # we can extend the lvm partition and
    # dynamically notify the kernel about it.
    sgdisk -e -d 3 -n 3:0:0 -t 3:8e00 ${device}
    partx -u ${device}  # notify the kernel
    pvresize ${device}3
else
    # this OS version is too old to be able
    # to notify the kernel of a partition
    # size update (at least in this case
    # where the partition is in use).
    # instead, we create one more new partition
    # and add it to the lvm group.
    sgdisk -e -n 4:0:0 -t 4:8e00 ${device}
    partx -a 4 ${device}  # notify the kernel
    pvcreate ${device}4
    vgextend $LVM_VG ${device}4
fi
lvextend -l+100%FREE /dev/$LVM_VG/ROOT
resize2fs /dev/$LVM_VG/ROOT

