#!/bin/sh
PACKAGES="lvm2 gdisk e2fsprogs"
eval "$chrooted_functions"
probe_target_optional_functions
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

optional_target_prepare_rootfs draft inside

if $target_custom_packages_exists
then
    PACKAGES="$PACKAGES $(target_custom_packages)"
fi

# install missing packages
echo -n "I: draft image - updating package manager database... "
apt-get update -qq
echo done

# fdisk & sfdisk are part of util-linux, but on newer OS they are
# in a dedicated package. Ensure it is installed.
if package_exists fdisk
then
    PACKAGES="$PACKAGES fdisk"
fi

if [ -z "$kernel_package" ]
then
    # kernel package not specified, install a default one
    kernel_search_regexp="^$(target_kernel_default_package)$"
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
for package in $kernel_package_found $PACKAGES
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

# for text console in kvm
if [ "$debug" = "1" ]
then
    # if OS init is upstart, create a service
    # in order to start a shell when the system is ready
    if [ -f '/sbin/upstart' ]
    then
        cat > ./etc/init/ttyS0.conf << EOF
start on stopped rc or RUNLEVEL=[12345]
stop on runlevel [!12345]

respawn
exec /sbin/getty -L 115200 ttyS0 xterm
EOF
    fi
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
target_configure_bootloader

# installing grub on this temporary work-image
# may not seem useful (it will be repeated on the final
# stick anyway), but actually it is:
# the files created there should be accounted when
# estimating the final stick minimal size).
target_install_bootloader

echo done

# check if target-specific code specified
# 'applied_kernel_cmdline' variable
if [ ! -z ${applied_kernel_cmdline+x} ]
then
    bootargs="$applied_kernel_cmdline"
    if [ -z "$bootargs" ]
    then
        bootargs="<none>"
    fi
    echo "I: draft image - kernel bootargs: $bootargs"
fi

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

optional_target_cleanup_rootfs draft inside
# umount all
undo_all

