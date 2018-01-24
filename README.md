## shrink-vmdk

Free unused space and shrink VMDK virtual disk with or without LVM.
Use on Linux host for VMDK virtual disks of powered-off Linux guests.

Uncomment the two lines with the `read` command if you want to create,
edit or delete files on the VMDK virtual disk.
- The 1st `read` command pauses the script after it mounted a partition.
- The 2nd `read` command pauses the script after it mounted a logical volume.

Requires:
- vmware-mount
- vmware-vdiskmanager
- needs to run as root

Limitations:
- Linux host and VMDK cannot have a volume group with the same name.
- Not tested with paths and file names containing spaces.

This software comes with absolutely no warranty. Use at your own risk.
