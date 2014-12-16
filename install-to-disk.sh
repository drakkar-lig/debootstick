#!/bin/bash

# TODO: save /dev/sda3
# TODO: determine stick and internal disk devices

# copy the partition scheme
sgdisk -Z /dev/sdb
sgdisk -R /dev/sdb /dev/sda
sgdisk -G /dev/sdb

# extend the last partition
sgdisk -d 3 -n 3:0:0 -t 3:8e00 /dev/sdb

# let the kernel update partition info
partx -u /dev/sdb

# copy partition contents
dd if=/dev/sda1 of=/dev/sdb1 bs=1M
dd if=/dev/sda2 of=/dev/sdb2 bs=1M

# move the lvm volume content on sdb3 
pvcreate /dev/sdb3
vgextend SN_VG /dev/sdb3
pvchange -x n /dev/sda3
pvmove /dev/sda3    # may take a little time
vgreduce SN_VG /dev/sda3

# fill the space available
lvextend -l+100%FREE /dev/SN_VG/ROOT
resize2fs /dev/SN_VG/ROOT

# install the bootloader
grub-install /dev/sdb

# make sure sda is not used anymore
pvremove /dev/sda3
partx -d /dev/sda

# TODO: restore /dev/sda3


