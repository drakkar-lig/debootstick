#!/bin/bash
THIS_DIR=$(cd $(dirname $0); pwd)
source $THIS_DIR/tools.sh

OLD_ROOT="$1"
SQUASHFS_CONTENTS_DIR="$2"

verify_space()
{
    generate_mtab
    estimated_size_needed=$(dir_size "$SQUASHFS_CONTENTS_DIR")
    majorated_size_needed=$((estimated_size_needed*4/3))
    size_available=$(fs_available_size "$OLD_ROOT")
    if [ $majorated_size_needed -gt $size_available ]
    then
        echo "Sorry - this device is too small. Cannot uncompress the system." 
        return 1
    fi
    return 0
}

# find device currently being booted
source /dbstck.conf     # get LVM_VG value
set -- $(pvs | grep $LVM_VG)
device=$(echo $1 | sed -e "s/.$//")

# occupy available space
echo "Extending disk space..."
sgdisk -e -d 3 -n 3:0:0 -t 3:8e00 ${device}
partx -u ${device}
pvresize ${device}3
lvextend -l+100%FREE /dev/$LVM_VG/ROOT
resize2fs /dev/$LVM_VG/ROOT

# extract the squashfs image contents
verify_space || drop_to_shell_and_halt
echo "Uncompressing..."
cp_big_dir_contents $SQUASHFS_CONTENTS_DIR $OLD_ROOT

