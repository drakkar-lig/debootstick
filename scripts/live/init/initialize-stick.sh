#!/bin/bash
THIS_DIR=$(cd $(dirname $0); pwd)
source $THIS_DIR/tools.sh

OLD_ROOT="$1"
SQUASHFS_CONTENTS_DIR="$2"

# get variables such as LVM_VG
# and DEVICE_MIN_SIZE_KB
source $OLD_ROOT/dbstck.conf

# find device currently being booted
set -- $(pvs | grep $LVM_VG)
device=$(echo $1 | sed -e "s/.$//")

# verify device size
device_size_kb=$(($(blockdev --getsz $device)/(1024/512)))
if [ $device_size_kb -lt $DEVICE_MIN_SIZE_KB ]
then
    echo "**** ERROR!!!! ******"
    echo "Sorry - this device is too small! Cannot uncompress the system." 
    echo "**** ERROR!!!! ******"
    drop_to_shell_and_halt
fi

# occupy available space
echo "Extending disk space..."
sgdisk -e -d 3 -n 3:0:0 -t 3:8e00 ${device}
partx -u ${device}
pvresize ${device}3
lvextend -l+100%FREE /dev/$LVM_VG/ROOT
resize2fs /dev/$LVM_VG/ROOT

# extract the squashfs image contents
echo "Uncompressing..."
cp_big_dir_contents $SQUASHFS_CONTENTS_DIR $OLD_ROOT

