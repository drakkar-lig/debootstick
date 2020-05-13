Trivial example:
```
$ debootstrap --arch=amd64 --variant=minbase trusty trusty_tree
$ debootstick --config-root-password-none trusty_tree img.dd
$ dd if=img.dd of=/dev/<your_device> bs=10M
```
Your USB device now embeds a live Ubuntu system and can be booted on any amd64 computer (UEFI or BIOS).

Embedded OS features
--------------------
The embedded system is:

- ready to be used (no installation step)
- viable in the long-term, fully upgradable (including the kernel and the bootloader)
- compatible with BIOS and UEFI systems

More information on the wiki
----------------------------
On the wiki at https://github.com/drakkar-lig/debootstick/wiki, you will find: 
* A more complete workflow for designing and testing an image
* How to install __debootstick__
* How to combine __debootstrap__ or __docker__ with __debootstick__
* How to test images with __kvm__
* Design notes, FAQ
