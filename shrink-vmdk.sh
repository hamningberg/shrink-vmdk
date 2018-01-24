#!/bin/bash

# Free unused space and shrink VMDK virtual disk with or without LVM.
# Use on Linux host for VMDK virtual disks of powered-off Linux guests.
#
# Uncomment the two lines with the `read` command if you want to create,
# edit or delete files on the VMDK virtual disk.
# - The 1st `read` command pauses the script after it mounted a partition.
# - The 2nd `read` command pauses the script after it mounted a logical
#   volume.
#
# Requires:
# - vmware-mount
# - vmware-vdiskmanager
# - needs to run as root
#
# Limitations:
# - Linux host and VMDK cannot have a volume group with the same name.
# - Not tested with paths and file names containing spaces.
#
# This software comes with absolutely no warranty. Use at your own risk.

BASENAME_SCRIPT=$(basename "$0")

cleanup() {
  EXIT_STATUS=$?

  mountpoint --quiet "${MOUNT_POINT_VOL}"
  if [ $? -eq 0 ]; then
    umount "${MOUNT_POINT_VOL}"
  fi

  if [ -n "${VG_NAME}" ]; then
    vgchange -a n ${VG_NAME}
  fi

  if [ -n "${LOOP_DEVICE}" ]; then
    losetup -d ${LOOP_DEVICE}
  fi

  # If umounting fails, try the following to cleanup:
  # dmsetup ls
  # dmsetup remove /dev/mapper/logical-vol-1
  # dmsetup remove /dev/mapper/logical-vol-2
  mountpoint --quiet "${MOUNT_POINT_IMAGE}"
  if [ $? -eq 0 ]; then
    vmware-mount -k "${VMDK_FILE}"
  fi

  rmdir "${MOUNT_POINT_VOL}"
  rmdir "${MOUNT_POINT_IMAGE}"

  if [ "${PERFORM_SHRINKING}" = 'true' ]; then
    # Backup and restore ownership of the VMDK file because
    # vmware-vdiskmanager changes it to the user and group
    # that runs vmware-vdiskmanager.
    # Do not use the %U:%G format for stat because it returns
    # UNKNOWN:UNKNOWN if user and group are unknown.
    VMDK_FILE_OWNER_GROUP=$(stat --format='%u:%g' "${VMDK_FILE}")
    vmware-vdiskmanager -k "${VMDK_FILE}"
    chown ${VMDK_FILE_OWNER_GROUP} "${VMDK_FILE}"
  fi

  trap '' EXIT INT QUIT TERM
  exit ${EXIT_STATUS}
}

cleanup_after_signal_caught() {
  EXIT_STATUS=$?
  trap '' EXIT
  cleanup
  exit ${EXIT_STATUS}
}


if [ -n "$1" -a -f "$1" ]; then
  VMDK_FILE="$1"
else
  echo "Usage: ${BASENAME_SCRIPT} VMDK-file" 1>&2
  exit 16
fi

if [ "$EUID" -ne 0 ]; then
  echo "${BASENAME_SCRIPT}: Run as root" 1>&2
  exit 15
fi

trap cleanup EXIT
trap cleanup_after_signal_caught INT QUIT TERM

MOUNT_POINT_IMAGE=$(mktemp -d -t "${BASENAME_SCRIPT}"-flat.XXXXXXXXXX)
MOUNT_POINT_VOL=$(mktemp -d -t "${BASENAME_SCRIPT}"-vol.XXXXXXXXXX)

for PARTITION_NUM in $(vmware-mount -p "${VMDK_FILE}" | egrep 'GPT EE Basic Data$|BIOS 83 Linux$' | cut -c-2); do
  echo "${BASENAME_SCRIPT}: Preparing for shrinking: Partition ${PARTITION_NUM} of $(basename ${VMDK_FILE})"
  vmware-mount "${VMDK_FILE}" ${PARTITION_NUM} "${MOUNT_POINT_VOL}"
  if [ $? -eq 0 ]; then
#    Uncomment the following line if you want to access the partitions one by one
#    read -rsp "Mounted partition ${PARTITION_NUM} on ${MOUNT_POINT_VOL}   Press [Enter] key to continue"
    vmware-vdiskmanager -p "${MOUNT_POINT_VOL}"
    vmware-mount -d "${MOUNT_POINT_VOL}"
    PERFORM_SHRINKING='true'
  fi
done

LVM_PARTITIONS="$(vmware-mount -p ${VMDK_FILE} | egrep 'GPT EE Linux Lvm$|BIOS 8E Unknown$')"

if [ -n "${LVM_PARTITIONS}" ]; then
  vmware-mount -f "${VMDK_FILE}" "${MOUNT_POINT_IMAGE}"
  if [ $? -eq 0 ]; then
    for VG_START_SECTOR in $(echo "${LVM_PARTITIONS}" | sed -r 's/^\s*[0-9]+\s+([0-9]+).+/\1/'); do
      VG_OFFSET=$((${VG_START_SECTOR} * 512))
      LOOP_DEVICE=$(losetup --find --show "${MOUNT_POINT_IMAGE}/flat" --offset ${VG_OFFSET})
      if [ -n "${LOOP_DEVICE}" ]; then
        MAPPED_DEVICES=''
        # It takes a few moments for the symlinks to appear
        while [ -z "${MAPPED_DEVICES}" ]; do
          sleep 1
          MAPPED_DEVICES=$(lvs --noheadings -o devices,lv_dm_path | grep ${LOOP_DEVICE}'(' | awk '{ print $2 }')
        done
        VG_NAME=$(lvs --noheadings -o devices,vg_name | grep ${LOOP_DEVICE}'(' | awk '{ print $2 }' | uniq)
        echo "${BASENAME_SCRIPT}: Iterating through volume group: ${VG_NAME}"
        for MAPPED_DEV in ${MAPPED_DEVICES}; do
          if [ $(lsblk --noheadings --output FSTYPE "${MAPPED_DEV}") != 'swap' ]; then
            echo "${BASENAME_SCRIPT}: Preparing for shrinking: ${MAPPED_DEV}"
            mount ${MAPPED_DEV} "${MOUNT_POINT_VOL}"
#            Uncomment the following line if you want to access the logical volumes one by one
#            read -rsp "Mounted $(basename ${MAPPED_DEV}) on ${MOUNT_POINT_VOL}   Press [Enter] key to continue"
            vmware-vdiskmanager -p "${MOUNT_POINT_VOL}"
            umount "${MOUNT_POINT_VOL}"
            PERFORM_SHRINKING='true'
          fi
        done
        vgchange -a n ${VG_NAME}
        VG_NAME=''
        losetup -d ${LOOP_DEVICE}
        LOOP_DEVICE=''
      fi
    done
  fi
fi
