
Custom disk layouts
-------------------

The default disk layout for your target is:
$DEFAULT_DISK_LAYOUT
(defined in file $DEFAULT_DISK_LAYOUT_FILE)

You can copy this file and edit the layout to fit your needs.
Then, use option '--disk-layout <layout-file>' when you
run debootstick.

About the size of a partition or lvm volume:
- "auto" means debootstick will select an appropriate size
- "<xx>[G|M]" (e.g. 1G or 50M) means debootstick should allocate
  exactly the specified size to this partition/volume
- "<xx>%" (e.g. 10%) means debootstick should allocate
  10% of the remaining free space to this partition/volume
- "max" means debootstick should allocate any
  remaining free space to this partition/volume

Restrictions:
- only one lvm partition (partition with type=lvm) is allowed
- lvm volumes cannot be declared if no lvm partition is declared
- "max" size is only allowed:
  * on the last partition
  * on one lvm volume only
- "<xx>%" size notation is only allowed:
  * on the last partition
  * on lvm volumes
- your custom layout should not remove partitions and lvm volumes
  present in the default disk layout, nor alter their type and
  mountpoint (you may modify their size), nor change the partition
  table type (dos or gpt).

Keep in mind that debootstick is supposed to generate a minimal
image, and, at this time, it has no knowledge about the size of
the device where the image will be copied.
Using "max" and "<xx>%" on partitions or lvm volumes allows
to ensure an apropriate disk layout, when the OS will expand
itself over the device, on first boot.
