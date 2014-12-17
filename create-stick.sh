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
EFI_PARTITION_SIZE_MB=10
BIOSBOOT_PARTITION_SIZE_MB=1
IMAGE_SIZE_MARGIN_MB=2
USB_SAMPLE_STICK_SIZE="2G"
DEBUG=0
MBR_BOOT_CODE_SIZE=446      # bytes
if [ "$DEBUG" = "1" ]
then
    CHROOTED_DEBUG="--debug"
fi
ROOT_PASSWORD="mot2passe"

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
    mkfs.ext4 -q -L ROOT -T default $1
}

format_stick()
{
    sgdisk  -n 1:0:+${EFI_PARTITION_SIZE_MB}M -t 1:ef00 \
            -n 2:0:+${BIOSBOOT_PARTITION_SIZE_MB}M -t 2:ef02 \
            -n 3:0:0 -t 3:8e00 $1
}

print_last_word()
{
    awk '{print $NF}'
}

make_compressed_fs()
{
    fs_tree=$(cd $1; pwd)
    
    # we will work with two subdirectories, 
    # '.fs.orig' & 'compressed'
    cd $fs_tree
    contents=$(ls -A)
    mkdir .fs.orig .fs.compressed
    mv $contents .fs.orig/
    
    cd .fs.orig

    # clean up
    rm -rf proc/* sys/* dev/* tmp/* run/*

    # some files should be preserved (not compressed)
    while read f
    do
        mkdir -p $(dirname $fs_tree/.fs.compressed/$f)
        mv $f $fs_tree/.fs.compressed/$f
    done << EOF
boot
bin/busybox
$(find lib -name squashfs.ko)
$(find lib -name overlayfs.ko)
EOF
    # move the init
    mv sbin/init sbin/init.orig
    
    # create compressed image
    mksquashfs $PWD $fs_tree/.fs.compressed/fs.squashfs

    # finalize compressed tree
    cd $fs_tree/.fs.compressed
    mkdir -p sbin proc sys tmp/os tmp/os_rw tmp/os_ro dev
    cp -p $ORIG_DIR/first-init.sh sbin/first-init.sh
    cd sbin
    ln -s first-init.sh init

    # keep only the compressed version in fs_tree
    cd $fs_tree/.fs.compressed
    mv $(ls -A) ..
    cd ..
    rm -rf .fs.orig .fs.compressed

    # leave the file system (allow unmounting it...)
    cd $TMP_DIR
}

mount -t tmpfs none $TMP_DIR
cd $TMP_DIR
mkdir work_root final_root

# step1: compute a stick size large enough for our work 
# (i.e. not for the final minimized version)
fs_size_estimation=$(du -sm $ORIG_TREE | awk '{print $1}')
work_image_size=$(( EFI_PARTITION_SIZE_MB + 
                    BIOSBOOT_PARTITION_SIZE_MB + 
                    4*fs_size_estimation))

# step2: create work image structure
rm -f $TMP_DD_FILE
dd status=noxfer if=/dev/zero bs=${work_image_size}M seek=1 count=0 of=$TMP_DD_FILE
work_image_loop_device=$(losetup -f)
losetup $work_image_loop_device $TMP_DD_FILE
format_stick $work_image_loop_device
kpartx -a $work_image_loop_device
set -- $(kpartx -l $work_image_loop_device | awk '{ print "/dev/mapper/"$1 }')
work_image_biosboot_dev=$2
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
umount work_root    # resize2fs' minimal size estimation is wrong when mounted
part3_start_sector=$(sgdisk -p $TMP_DD_FILE | tail -n 1 | awk '{print $2}')
sector_size=$(sgdisk -p $TMP_DD_FILE | grep 'sector size' | awk '{print $(NF-1)}')
fs_block_size=$(tune2fs -l $sn_root_dev | grep 'Block size' | print_last_word)
min_fs_size_in_blocks=$(resize2fs -P $sn_root_dev 2>/dev/null | print_last_word)
min_fs_size_in_sectors=$((min_fs_size_in_blocks * (fs_block_size/sector_size)))
min_stick_size_in_sectors=$((   part3_start_sector +
                                min_fs_size_in_sectors +
                                IMAGE_SIZE_MARGIN_MB * (1024 * 1024 / sector_size)))

# step6: copy work version to the final image (with minimal size)

# rename the lvm volume group of the work image to avoid any conflict
vgrename $LVM_VG ${LVM_VG}_WORK
# copy the master boot record code
rm -f $DD_FILE
dd status=noxfer if=$TMP_DD_FILE of=$DD_FILE bs=$MBR_BOOT_CODE_SIZE count=1
# modify the size of the final image 
dd status=noxfer bs=$sector_size seek=$min_stick_size_in_sectors count=0 of=$DD_FILE
# format the final image like the working one
format_stick $DD_FILE
final_image_loop_device=$(losetup -f)
losetup $final_image_loop_device $DD_FILE
kpartx -a $final_image_loop_device
set -- $(kpartx -l $final_image_loop_device | awk '{ print "/dev/mapper/"$1 }')
sn_efi_dev=$1
final_image_biosboot_dev=$2
sn_lvm_dev=$3
dd status=noxfer bs=1M if=$work_image_biosboot_dev of=$final_image_biosboot_dev
pvcreate $sn_lvm_dev
vgcreate ${LVM_VG} $sn_lvm_dev
lvcreate -n ROOT -l 100%FREE $LVM_VG
sn_root_dev=/dev/$LVM_VG/ROOT
make_ext4_fs $sn_root_dev
mount $sn_root_dev final_root
mount /dev/${LVM_VG}_WORK/ROOT work_root
cp -rp work_root/* final_root/
echo TODO: meilleure estimation de taille mini en faisant une copie dans un filesystem vierge

# step7: install BIOS bootloader

# we have to make the environment look 'standard'
# for grub-install and update-grub to work properly. 
# this means that, once we chroot, / must be
# the real root that will be used in our live os,
# and same for /boot.
# we have to deal with the fact that most of the system 
# has been compressed in a squashfs image, including 
# the tools we want to call (grub-install, update-grub) 
# and their environment (config files, shared libs...). 
mkdir compressed_fs
mount -o ro final_root/fs.squashfs compressed_fs
cd compressed_fs
for dir in $(ls -A)
do  # consider not-empty dirs only
    if [ -d $dir -a "$(ls -A $dir)" ]
    then 
        mkdir -p ../final_root/$dir
        mount -o bind,ro $dir ../final_root/$dir
        echo $dir >> ../tmp_mounts
    fi
done
cd ../final_root
cp -p $ORIG_DIR/chrooted_grub_install.sh .
chroot . ./chrooted_grub_install.sh $final_image_loop_device
rm chrooted_grub_install.sh

umount $(cat ../tmp_mounts)
cd ..

umount compressed_fs work_root final_root

# step8: setup the EFI boot partition
mkfs.vfat -n DBSTCK_EFI $sn_efi_dev
cd $TMP_DIR
mkdir -p efi/part
cd efi
mount $sn_efi_dev part
mkdir -p part/EFI/BOOT boot/grub
cat > boot/grub/grub.cfg << EOF
insmod part_gpt
insmod lvm
search --set rootfs --label ROOT
configfile (\$rootfs)/boot/grub/grub.cfg
EOF
grub-mkstandalone \
        --directory="/usr/lib/grub/x86_64-efi/" --format="x86_64-efi"   \
        --compress="gz" --output="part/EFI/BOOT/BOOTX64.efi"            \
        "boot/grub/grub.cfg"
echo TODO: ajouter 10% a la taille de part/EFI/BOOT/BOOTX64.efi pour la taille de la partition devrait largement suffire
umount part
cd ..

# step9: clean up
dmsetup remove /dev/${LVM_VG}_WORK/ROOT
dmsetup remove /dev/${LVM_VG}/ROOT
kpartx -d $work_image_loop_device
kpartx -d $final_image_loop_device
losetup -d $work_image_loop_device
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

