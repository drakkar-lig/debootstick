# do not specify the shebang, because this should actually be called
# by "/tmp/busybox sh", and lintian emits a warning.
loop_device=$1

eval "$chrooted_functions"
start_failsafe_mode

# classical mounts
mount_virtual_filesystems

export busybox_path="/tmp/busybox"

# The current filesystem root is a very limited system, mostly
# reduced to /bin/busybox and a compressed filesystem image 
# at /fs.squashfs.
# We need to run grub-install and update-grub and these tools are 
# in this compressed filesystem image.
# However we cannot just mount it and chroot, because / and
# /boot would be changed, and thus grub would not be set up
# correctly: we must maintain / and /boot as they are now.
# So, instead of mounting the squashfs image at /, we will 
# bind-mount most of the subdirectories it contains on the same 
# directory of this current root.
# Thus, after this operation, we will have for example 
# update-grub available at /bin/sbin/update-grub, and any 
# conf file or library is needs in the appropriate place, while
# still maintaining / as it is now. 
# 
# One more subtlety: we must ensure that we only use busybox applets
# during this whole step. That's why we prefix commands with 
# /tmp/busybox below. Without this, after the loop iteration where
# /bin is bind-mounted, calling 'mount' would actually call 
# '/bin/mount', but since '/lib' or '/usr' or not bind-mounted yet,
# the dynamic libraries needed by '/bin/mount' would fail to load.
cd /tmp
mkdir compressed_fs
failsafe mount -t squashfs -o ro /fs.squashfs /tmp/compressed_fs
cd compressed_fs
for dir in $(ls -A)
do  # consider sub-dirs, and skip /tmp
    if [ -d $dir -a $dir != "tmp" ]
    then
        # ignore empty sub-dirs
        if [ "$($busybox_path ls -A $dir)" ]
        then
            $busybox_path mkdir -p /$dir
            failsafe busybox_mount -o bind,ro $dir /$dir
        fi
    fi
done

# let grub find our virtual device
cd /boot/grub
cat > device.map << END_MAP
(hd0) $loop_device
END_MAP

# install
quiet_grub_install $loop_device

# remove previous file
rm /boot/grub/device.map

# umount things
undo_all

