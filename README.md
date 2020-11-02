debootstick
===========
_Turn a chroot environment into a bootable image._

Trivial example:
----------------
```
$ debootstrap --variant=minbase focal focal_tree http://archive.ubuntu.com/ubuntu/
$ debootstick --config-root-password-none focal_tree img.dd
$ dd if=img.dd of=/dev/<your_device> bs=10M
```
Your USB device now embeds a live Ubuntu system and can be booted
on any UEFI or BIOS computer.

From docker image to raspberry pi SD:
-------------------------------------
A more interesting example:
```
$ docker run -it --name mycontainer --entrypoint /bin/bash eduble/rpi-mini
> [... customize ...]
> exit
$ mkdir mycontainer_fs; cd mycontainer_fs
$ docker export mycontainer | tar xf - ; docker rm mycontainer
$ cd ..
$ debootstick --config-root-password-none mycontainer_fs rpi.dd
$ dd if=rpi.dd of=/dev/mmcblk0 bs=10M
```
Your **Raspberry Pi** now boots your customized OS!

Embedded OS features
--------------------
The embedded system is:

- ready to be used (no installation step)
- viable in the long-term, fully upgradable (including the kernel and the bootloader)
- compatible with BIOS and UEFI systems (PC) or Raspberry Pi boards

More information on the wiki
----------------------------
On the wiki at https://github.com/drakkar-lig/debootstick/wiki, you will find:
* A more complete workflow for designing and testing an image
* How to install __debootstick__
* How to combine __debootstrap__ or __docker__ with __debootstick__
* How to test images with __kvm__
* Design notes, FAQ

