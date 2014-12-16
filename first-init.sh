#!/bin/busybox sh

# remount / read-write
mount -o remount,rw /

# mount compressed image
insmod $(find . -name squashfs.ko)
insmod $(find . -name overlayfs.ko)
mount fs.squashfs /tmp/os_ro
mount -t overlayfs -o lowerdir=/tmp/os_ro,upperdir=/tmp/os_rw \
        none /tmp/os

# bind classic mounts
for mp in /proc /sys /dev /dev/pts
do
    mount -o bind $mp /tmp/os$mp
done

# exchange roots
mkdir /tmp/os/old-root
pivot_root /tmp/os /tmp/os/old-root

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
echo "Uncompressing..."
cp -rp /old-root/tmp/os_ro/* /old-root/

# reset roots as before
pivot_root /old-root /old-root/tmp/os

# umount things
for mp in /proc /sys /dev/pts /dev
do
    umount /tmp/os$mp
done
umount /tmp/os /tmp/os_ro

# remove squashfs image (not needed anymore)
rm fs.squashfs

# restore and start the usual init
rm /sbin/init
mv /sbin/init.orig /sbin/init
exec /sbin/init $*

