#!/bin/bash
set -e

if [ ! -d "$1" ]
then
    echo "Usage: $0 <fs_tree_dir>" >&2
    exit
fi

# ensure we are root
if [ "$USER" != "root" ]
then
    sudo $0 $*
    exit
fi
ORIG_DIR=$(cd $(dirname $0); pwd)
ORIG_TREE="$(cd "$1"; pwd)"
STICK_OS_ID=$(uuidgen)
LVM_VG="DBSTCK-$STICK_OS_ID"
TMP_DIR=$(mktemp -d)
DD_FILE=$TMP_DIR/disk.dd
TMP_DD_FILE=$TMP_DIR/tmp.disk.dd
BIOSBOOT_PARTITION_SIZE_KB=1024
IMAGE_SIZE_MARGIN_KB=0  # fs size estimation is enough pessimistic
USB_SAMPLE_STICK_SIZE="2G"
MKSQUASHFS_OPTS="-b 1M -comp xz"
FAT_OVERHEAD_PERCENT=10
FS_OVERHEAD_PERCENT=15
LVM_OVERHEAD_PERCENT=4
DEBUG=1
if [ "$DEBUG" = "1" ]
then
    CHROOTED_DEBUG="--debug"
fi
ROOT_PASSWORD="mot2passe"
DD="dd status=none"

make_ext4_fs()
{
    # IMPORTANT NOTE.
    # We try to create a USB stick as small as possible.
    # However, the embedded system may later by copied on a 
    # potentially large disk. 
    # Therefore, we specify the option '-T default' to mkfs.ext4.
    # This allows to select 'default' ext4 features even if this
    # filesystem might be considered 'small' for now.
    # This may seem cosmetic but it's not: if we omit this, 
    # when we move to a large disk, resize2fs apparently enables 
    # the 'meta_bg' option (supposedly trying to adapt as much as 
    # possible this 'small' filesystem to a much larger device). 
    # Since this option is not handled by grub, it prevents the 
    # system from booting properly.
    mkfs.ext4 -F -q -L ROOT -T default -m 2 $1
}

format_stick()
{
    device=$1
    efi_partition_size_kb=$2
    sgdisk  -n 1:0:+${efi_partition_size_kb}K -t 1:ef00 \
            -n 2:0:+${BIOSBOOT_PARTITION_SIZE_KB}K -t 2:ef02 \
            -n 3:0:0 -t 3:8e00 $device
}

print_last_word()
{
    awk '{print $NF}'
}

make_compressed_fs()
{   
    echo "Compressing the system..."
    fs_tree=$(cd $1; pwd)
    
    # we will work with two subdirectories, 
    # '.fs.orig' & 'compressed'
    cd $fs_tree
    contents=$(ls -A)
    mkdir .fs.orig .fs.compressed
    mv $contents .fs.orig/
    
    cd .fs.orig

    # clean up
    rm -rf proc/* sys/* dev/* tmp/* run/* /var/cache/*

    # some files should be available early at boot 
    # (thus not compressed in the squashfs image)
    while read f
    do
        mkdir -p $(dirname $fs_tree/.fs.compressed/$f)
        mv $f $fs_tree/.fs.compressed/$f
    done << EOF
boot
bin/busybox
$(find lib -name squashfs.ko)
EOF

    # move the init
    mv sbin/init sbin/init.orig
    
    # create compressed image
    mksquashfs $PWD $fs_tree/.fs.compressed/fs.squashfs $MKSQUASHFS_OPTS

    # finalize compressed tree
    cd $fs_tree/.fs.compressed
    mkdir -p sbin proc sys tmp/os tmp/os_rw tmp/os_ro dev
    cp -p $ORIG_DIR/first-init.sh sbin/debootstick-first-init.sh
    cd sbin
    ln -s debootstick-first-init.sh init

    # keep only the compressed version in fs_tree
    cd $fs_tree/.fs.compressed
    mv $(ls -A) ..
    cd ..
    rm -rf .fs.orig .fs.compressed

    # leave the file system (allow unmounting it...)
    cd $TMP_DIR
}

compute_min_fs_size()
{
	fs_mount_point=$1
	
	data_size_in_kbytes=$(du -sk $fs_mount_point | awk '{print $1}')
	min_fs_size_in_kbytes=$((data_size_in_kbytes*100/(100-FS_OVERHEAD_PERCENT)))

	# return this size
	echo $min_fs_size_in_kbytes
}

mount -t tmpfs none $TMP_DIR
cd $TMP_DIR
mkdir -p work_root final_root efi/part efi/boot/grub

# step0: generate EFI bootloader image
cd efi
cat > boot/grub/grub.cfg << EOF
insmod part_gpt
insmod lvm
search --set rootfs --label ROOT
configfile (\$rootfs)/boot/grub/grub.cfg
EOF
grub-mkstandalone \
        --directory="/usr/lib/grub/x86_64-efi/" --format="x86_64-efi"   \
        --compress="gz" --output="BOOTX64.efi"            \
        "boot/grub/grub.cfg"
efi_image_size_bytes=$(stat -c "%s" BOOTX64.efi)
efi_partition_size_kb=$((efi_image_size_bytes/1024*100/(100-FAT_OVERHEAD_PERCENT)))
cd ..

# step1: compute a stick size large enough for our work 
# (i.e. not for the final minimized version)
fs_size_estimation=$(du -sk $ORIG_TREE | awk '{print $1}')
work_image_size=$(( efi_partition_size_kb + 
                    BIOSBOOT_PARTITION_SIZE_KB + 
                    4*fs_size_estimation))

# step2: create work image structure
rm -f $TMP_DD_FILE
$DD if=/dev/zero bs=${work_image_size}k seek=1 count=0 of=$TMP_DD_FILE
work_image_loop_device=$(losetup -f)
losetup $work_image_loop_device $TMP_DD_FILE
format_stick $work_image_loop_device $efi_partition_size_kb
kpartx -a $work_image_loop_device
set -- $(kpartx -l $work_image_loop_device | awk '{ print "/dev/mapper/"$1 }')
sn_lvm_dev=$3
pvcreate $sn_lvm_dev
vgcreate $LVM_VG $sn_lvm_dev
lvcreate -n ROOT -l 100%FREE ${LVM_VG}
sn_root_dev=/dev/$LVM_VG/ROOT
make_ext4_fs $sn_root_dev
mount $sn_root_dev work_root

# step3: copy original tree to work image and modify it
cd work_root/
cp -rp $ORIG_TREE/* .
mkdir -p opt/debootstick
cp -rp $ORIG_DIR/live opt/debootstick/live
cp -p $ORIG_DIR/chrooted_customization.sh .
chroot . ./chrooted_customization.sh $CHROOTED_DEBUG \
                $work_image_loop_device $ROOT_PASSWORD
rm ./chrooted_customization.sh
cat > dbstck.conf << EOF
LVM_VG=$LVM_VG
EOF
cd ..

# step4: compress the filesystem tree
make_compressed_fs work_root

# step5: compute minimal size of final stick
cd $TMP_DIR
min_fs_size_in_kbytes=$(compute_min_fs_size work_root)
part3_start_sector=$(sgdisk -p $TMP_DD_FILE | tail -n 1 | awk '{print $2}')
sector_size=$(sgdisk -p $TMP_DD_FILE | grep 'sector size' | awk '{print $(NF-1)}')
min_part3_size_in_kbytes=$((min_fs_size_in_kbytes * 100/(100-LVM_OVERHEAD_PERCENT)))
min_stick_size_in_kbytes=$((    part3_start_sector / 1024 * sector_size +
                                min_part3_size_in_kbytes +
                                IMAGE_SIZE_MARGIN_KB))

# step6: copy work version to the final image (with minimal size)

# rename existing lvm vg in order to avoid a conflict
vgrename $LVM_VG ${LVM_VG}_WORK

# prepare a final image with minimal size
rm -f $DD_FILE
$DD bs=1024 seek=$min_stick_size_in_kbytes count=0 of=$DD_FILE
# format the final image like the working one
format_stick $DD_FILE $efi_partition_size_kb
final_image_loop_device=$(losetup -f)
losetup $final_image_loop_device $DD_FILE
kpartx -a $final_image_loop_device
set -- $(kpartx -l $final_image_loop_device | awk '{ print "/dev/mapper/"$1 }')
sn_efi_dev=$1
sn_lvm_dev=$3
pvcreate $sn_lvm_dev
vgcreate ${LVM_VG} $sn_lvm_dev
lvcreate -n ROOT -l 100%FREE $LVM_VG
sn_root_dev=/dev/$LVM_VG/ROOT
make_ext4_fs $sn_root_dev
mount $sn_root_dev final_root
cp -rp work_root/* final_root/
umount work_root
dmsetup remove /dev/${LVM_VG}_WORK/ROOT
kpartx -d $work_image_loop_device
losetup -d $work_image_loop_device
rm -f $work_image_loop_device

# step7: install BIOS bootloader

cd final_root
# since the size of the filesystem mounted there is minimized,
# creating new files may cause problems.
# so we will use the directory /tmp that we mount in memory.
mount -t tmpfs none tmp
# /bin will be bind-mounted (see chrooted_grub_install.sh), 
# making /bin/busybox unaccessible.
# So we will use a copy in /tmp instead.
cp -p bin/busybox tmp
cp -p $ORIG_DIR/chrooted_grub_install.sh tmp
chroot . tmp/busybox sh tmp/chrooted_grub_install.sh $final_image_loop_device
umount tmp
cd ..

umount final_root

# step8: setup the EFI boot partition
mkfs.vfat -n DBSTCK_EFI $sn_efi_dev
cd $TMP_DIR/efi
mount $sn_efi_dev part
mkdir -p part/EFI/BOOT
mv BOOTX64.efi part/EFI/BOOT/
umount part
cd ..

# step9: clean up
dmsetup remove /dev/${LVM_VG}/ROOT
kpartx -d $final_image_loop_device
losetup -d $final_image_loop_device
cd $ORIG_DIR
mkdir -p out

cp $DD_FILE out/
chmod a+rw out/disk.dd
umount -lf $TMP_DIR
rm -rf $TMP_DIR
echo out/disk.dd ready.

echo " ---- to test it with kvm: ----"
echo " * simulate copy on a larger USB stick by increasing the file size"
echo "truncate -s $USB_SAMPLE_STICK_SIZE out/disk.dd"
echo " * test it (BIOS):"
echo "kvm -hda out/disk.dd -nographic"
echo " * test it (EFI):"
echo "kvm -bios /usr/share/qemu/OVMF.fd -hda out/disk.dd -nographic; reset"

