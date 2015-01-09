debootstick
===========
_Build customized and featureful Ubuntu-live sticks._

Trivial example:
```
$ debootstrap --arch=amd64 --variant=minbase trusty trusty_tree
$ debootstick --config-root-password-none trusty_tree img.dd
$ dd if=img.dd of=/dev/<your_device> bs=10M
```
Your USB device now embeds a live Ubuntu system and can be booted on any amd64 computer (UEFI or BIOS).

__WARNING: this software is in alpha state. USE AT YOUR OWN RISK.__

The concept
-----------
Generating a bootable image may be seen as a 3-steps process:

1. Generate a filesystem tree
2. Customize it
3. Build a bootable image

__debootstick__ takes care of step 3 only. As such, it follows the [UNIX philosophy](http://en.wikipedia.org/wiki/Unix_philosophy#Program_Design_in_the_UNIX_Environment): this limited scope makes it good at collaborating with other tools, such as __debootstrap__, __chroot__, or even __docker__.

Embedded OS features
--------------------
The embedded system is:

- ready to be used (no installation step, only an automatic decompression at 1st boot)
- viable in the long-term, fully upgradable (including the kernel and the bootloader)
- compact
- compatible with BIOS and UEFI systems

Installing debootstick
----------------------
A package has been generated for Ubuntu 14.04.

Type:
```
$ add-apt-repository ppa:debootstick/ppa
$ apt-get update
$ apt-get install debootstick
```

Standard workflow: debootstrap, debootstick and kvm
---------------------------------------------------

1. Generate a filesystem tree:
 ```
 $ debootstrap --arch=amd64 --variant=minbase trusty /tmp/trusty_tree
 ```
 
2. Customize it:
 ```
 $ chroot /tmp/trusty_tree
 $ passwd       # update root password
 $ [...]        # other customizations
 $ exit         # exit from chroot
 ```
 
3. Generate the bootable image:
 ```
 $ debootstick /tmp/trusty_tree /tmp/img.dd
 ```
 
4. Test it with kvm.
 ```
 $ cp /tmp/img.dd /tmp/img.dd-test  # let's work on a copy, our test is destructive
 $ truncate -s 2G /tmp/img.dd-test  # simulate a copy on a 2G-large USB stick
 $ kvm -hda /tmp/img.dd-test        # the test itself (BIOS mode)
 ```
 
5. Copy the boot image to a USB stick or disk.
 ```
 $ dd bs=10M if=/tmp/img.dd of=/dev/your-device
 ```

Note: it is also possible to test the UEFI boot with kvm, if you have the __ovmf__ package installed, by adding `-bios /path/to/OVMF.fd` to the `kvm` command line.


Turning a docker container into a bootable image
------------------------------------------------
__Docker__ is a convenient tool when setting up an operating system. But, at the end of the process, sometimes we want to run this operating system on a real machine, instead of a container. With `debootstick`, we can achieve this easily. Here are a few guidelines.

First, we can retrieve the filesystem tree of a docker container by using the `docker export` command. However, since this command accepts a docker container and not a docker image, we will have to generate a container from the image first. Here is the most atomic way to do it:
```
$ docker run --name mycontainer ubuntu:14.04 true
```
We request a new container to be created from image `ubuntu:14.04`, in order to run the command `/bin/true` (it is a command that does nothing, but since we need one...).

We can know retrieve the content of this container, and then remove it.
```
$ mkdir mycontainer_fs 
$ cd mycontainer_fs/
$ docker export mycontainer | tar xf -
$ docker rm mycontainer   # not needed anymore
```

We now have the filesystem tree in the current directory `mycontainer_fs`:
```
$ ls
bin  boot  dev  etc  home  lib  lib64  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
$ 
```

The OS embedded in official Ubuntu docker images is slightly customized. In particular, starting services is disallowed. We have to revert this:
```
$ chroot .
$ rm /usr/sbin/policy-rc.d
$ dpkg-divert --remove /sbin/initctl
$ mv /sbin/initctl.distrib /sbin/initctl
$ exit	# from chroot
```

We have to set or delete the root password, to be able to login to our system.
```
$ chroot . passwd -d root
```
(Alternatively, we could add an option --config-root-password-[ask|none] when using __debootstick__ below.)

We also need the DNS to be properly configured inside the filesystem, for __debootstick__ to run correctly. (In the future, __debootstick__ should handle this itself.)
```
$ cp /etc/resolv.conf ./etc/resolv.conf
```

We can now use debootstick:
```
$ cd ..
$ debootstick mycontainer_fs img_from_docker.dd
```

And that's it. We have our image. 

Before dumping it to a USB device, we may prefer to test it:
```
$ cp img_from_docker.dd img_from_docker.dd-test
$ truncate -s 2G img_from_docker.dd-test
$ kvm -hda img_from_docker.dd-test -serial mon:stdio -nographic
[...grub menu...]
[...kernel messages...]
Uncompressing...
|****************************************| 100%
[...]

Ubuntu 14.04.1 LTS localhost ttyS0

localhost login: root
Welcome to Ubuntu 14.04.1 LTS ([...])
[...]

root@localhost:~# echo "We are inside the VM!"
We are inside the VM!
root@localhost:~# 
```


