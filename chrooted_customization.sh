#!/bin/bash
set -e
set -x
PACKAGES="linux-image-virtual lvm2 busybox-static gdisk grub-pc"

if [ "$1" = "--debug" ]
then
    debug=1
    shift
else
    debug=0
fi

loop_device=$1
root_password=$2

mount -t devtmpfs none /dev
mount -t proc none /proc
mount -t devpts none /dev/pts
mount -t sysfs none /sys
export DEBIAN_FRONTEND=noninteractive

cat > etc/apt/apt.conf.d/minimal << EOF
DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };
APT::Update::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true"; };
Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";
Acquire::GzipIndexes "true"; Acquire::CompressionTypes::Order:: "gz";
Acquire::Languages "none";
EOF

# let grub find our virtual device
# we will install the bootloader on the final device anyway,
# this is only useful to avoid warnings
mkdir -p boot/grub
cat > boot/grub/device.map << END_MAP
(hd0) $loop_device
END_MAP

# install missing packages
apt-get update -q
to_be_installed=""
for package in $PACKAGES
do
    installed=$(dpkg-query -W --showformat='${Status}\n' \
                    $package 2>/dev/null | grep -c "^i" || true)
if [ $installed -eq 0 ]
then
    to_be_installed="$to_be_installed $package"
fi
done
if [ "$to_be_installed" != "" ]
then
    apt-get -q -y --no-install-recommends install $to_be_installed
fi

apt-get -q clean
rm -rf /var/lib/apt/lists/*

# for text console in kvm
if [ "$debug" = "1" ]
then   
    # display the grub interface
    cat > ./etc/default/grub << EOF
GRUB_TIMEOUT=4
GRUB_DISTRIBUTOR="Magnetic Linux"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF
    # start a shell when the system is ready
    cat > ./etc/init/ttyS0.conf << EOF
start on stopped rc or RUNLEVEL=[12345]
stop on runlevel [!12345]

respawn
exec /sbin/getty -L 115200 ttyS0 xterm
EOF
fi

echo "root:$root_password" | chpasswd

# work around grub displaying error message with our LVM setup
# note: even if the file etc/grub.d/10_linux is re-created
# after an upgrade of the package grub-common, our script
# 09_linux_custom will be executed first and take precedence.
sed -e 's/quick_boot=.*/quick_boot=0/' etc/grub.d/10_linux > \
        etc/grub.d/09_linux_custom
chmod +x etc/grub.d/09_linux_custom
rm etc/grub.d/10_linux

rm boot/grub/device.map

umount /sys /dev/pts /proc /dev
