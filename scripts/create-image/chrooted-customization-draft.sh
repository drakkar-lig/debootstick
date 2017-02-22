#!/bin/sh
OTHER_PACKAGES="lvm2 gdisk grub-pc"
eval "$chrooted_functions"
start_failsafe_mode
# in the chroot commands should use /tmp for temporary files
export TMPDIR=/tmp

if [ "$1" = "--debug" ]
then
    debug=1
    shift
else
    debug=0
fi

loop_device=$1
root_password_request=$2
shift 2
# eval <var>=<value> parameters
while [ ! -z "$1" ]
do
    eval "$1"
    shift
done

failsafe mount -t proc none /proc
failsafe_mount_sys_and_dev
export DEBIAN_FRONTEND=noninteractive LANG=C

# if update-grub is called as part of the package installation
# it should properly find our virtual device.
# (we will properly install the bootloader on the final device
# anyway, this is only useful to avoid warnings)
update_grup_device_map $loop_device

# install missing packages
echo -n "I: draft image - updating package manager database... "
apt-get update -qq
echo done

if [ -z "$kernel_package" ]
then
    # kernel package not specified, install a default one
    # * ubuntu: linux-image-generic
    # * debian on i386: linux-image-686-pae
    # * debian on amd64: linux-image-amd64
    case "$target_arch" in
    "amd64")
        kernel_search_regexp="^linux-image-((generic)|(amd64))$"
        ;;
    "i386")
        kernel_search_regexp="^linux-image-((generic)|(686-pae))$"
        ;;
    esac
    error_if_missing="$(
        echo "E: no linux kernel package found."
        echo "E: Run 'debootstick --help-os-support' for more info."
    )"
else
    kernel_search_regexp="^${kernel_package}$"
    error_if_missing="E: no such package '$kernel_package'"
fi

kernel_package_found=$(
        list_available_packages "$kernel_search_regexp")
if [ -z "$kernel_package_found" ]
then
    echo "$error_if_missing"
    exit 1
fi

to_be_installed=""
for package in $kernel_package_found $OTHER_PACKAGES
do
    if [ $(package_is_installed $package) -eq 0 ]
    then
        to_be_installed="$to_be_installed $package"
    fi
done

[ -f /sbin/init ] || to_be_installed="$to_be_installed init"

if [ "$to_be_installed" != "" ]
then
    echo -n "I: draft image - installing packages:${to_be_installed}... "
    install_packages $to_be_installed
    echo done
fi

# keep it small
apt-get -qq clean
rm -rf /var/lib/apt/lists/*

# tune LVM config
tune_lvm

if [ "$config_grub_on_serial_line" -gt 0 ]
then
    # display the grub interface on serial line
    cat >> ./etc/default/grub << EOF
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF
fi

# grub conf:
# * add our custom boot parameters
# * fix obsolete options in /etc/default/grub
#   (https://bugs.launchpad.net/ubuntu/+source/grub2/+bug/1258597)
. /etc/default/grub
LINUX_OPTIONS="rootdelay=3 $kernel_bootargs"
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX $LINUX_OPTIONS"
sed -i -e "s/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE_LINUX\"/" \
       -e "s/^GRUB_HIDDEN/#GRUB_HIDDEN/g" \
        /etc/default/grub

# remove the "quiet" option from kernel boot cmdline
# if instructed by kernel_strip_quiet_from_cmdline=1.
if [ "x${kernel_strip_quiet_from_cmdline}" = "x1" ]; then
   sed -i -e '/^GRUB_CMDLINE_LINUX/s/\s*quiet//g' ./etc/default/grub
fi

# for text console in kvm
if [ "$debug" = "1" ]
then
    # start a shell when the system is ready
    cat > ./etc/init/ttyS0.conf << EOF
start on stopped rc or RUNLEVEL=[12345]
stop on runlevel [!12345]

respawn
exec /sbin/getty -L 115200 ttyS0 xterm
EOF
fi

# set the root password if requested
case "$root_password_request" in
    "NO_REQUEST")
        true            # nothing to do
    ;;
    "NO_PASSWORD")
        passwd -dq root  # remove root password
    ;;
    *)                  # change root password
        echo "$root_password_request" | chpasswd
    ;;
esac

echo -n "I: draft image - setting up bootloader... "
# disable quickboot:
# work around grub displaying error message with our LVM setup
# disable vt_handoff:
# the linux console should be visible during startup (especially
# if we must enter the root password, or in installer-mode), do
# not switch to vt7.
# note: even if the file etc/grub.d/10_linux is re-created
# after an upgrade of the package grub-common, our script
# 09_linux_custom will be executed first and take precedence.
sed -i -e 's/quick_boot=.*/quick_boot=0/' \
       -e 's/vt_handoff=.*/vt_handoff=0/' etc/grub.d/10_linux
mv etc/grub.d/10_linux etc/grub.d/09_linux_custom

# install grub on this temporary work-image
# This may not seem useful (it will be repeated on the final
# stick anyway), but actually it is:
# the files created there should be accounted when
# estimating the final stick minimal size).
quiet_grub_install $loop_device

rm boot/grub/device.map
echo done

echo -n "I: draft image - updating fstab... "
update_fstab $final_lvm_vg
echo done

if [ "$config_hostname" != "" ]
then
    echo -n "I: draft image - setting hostname... "
    echo "$config_hostname" > /etc/hostname
    echo done
fi

echo -n "I: draft image - performing sanity checks... "
should_update_hosts_file=$(missing_or_empty /etc/hosts)
should_update_locale_file=$(missing_or_empty /etc/default/locale)
echo done

if [ $should_update_hosts_file -eq 1 ]
then
    echo -n "I: draft image - generating /etc/hosts (it was empty or missing)... "
    generate_hosts_file
    echo done
fi

if [ $should_update_locale_file -eq 1 ]
then
    echo -n "I: draft image - adding missing locale definition... "
    mkdir -p /etc/default
    echo "LC_ALL=C" > /etc/default/locale
    echo done
fi

# umount all
undo_all

