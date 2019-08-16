#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

# TARGET_DISK may be set as an environment variable

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Script must be executed with root privileges"
        exit 1
    fi
}

dependencies() {
    apt-add-repository universe
    apt install -y debootstrap gdisk zfs-initramfs
}

select_disk() {
    local disks
    local options
    if [ -z $TARGET_DISK ]; then
        shopt -s nullglob
        disks=(/dev/disk/by-id/*)
        shopt -u nullglob
        options=()
        
        for i in "${!disks[@]}"; do
            options+=("${disks[i]}")
            options+=("")
        done

        TARGET_DISK=$(whiptail --title "Disk to install to" --menu \
        "Choose the device to install to (full disk)" 20 78 ${#disks[@]} \
        "${options[@]}" \
        3>&1 1>&2 2>&3)
    fi
    echo "The chosen disk is: ${TARGET_DISK}"
}

format_disk() {
    sgdisk --zap-all "${TARGET_DISK}"
}

create_partitions() {
    sgdisk -n2:1M:+512M \
    -t2:EF00 \
    "${TARGET_DISK}"

    sgdisk -n3:0:+512M \
    -t3:BF01 \
    "${TARGET_DISK}"

    sgdisk -n4:0:0 \
    -t4:BF01 \
    "${TARGET_DISK}"
}

create_zfs_pools() {
    zpool create -o ashift=12 \
      -d \
      -o feature@async_destroy=enabled \
      -o feature@bookmarks=enabled \
      -o feature@embedded_data=enabled \
      -o feature@empty_bpobj=enabled \
      -o feature@enabled_txg=enabled \
      -o feature@extensible_dataset=enabled \
      -o feature@filesystem_limits=enabled \
      -o feature@hole_birth=enabled \
      -o feature@large_blocks=enabled \
      -o feature@lz4_compress=enabled \
      -o feature@spacemap_histogram=enabled \
      -o feature@userobj_accounting=enabled \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O devices=off \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      -O mountpoint=/ \
      -R /mnt \
      bpool \
      "${TARGET_DISK}-part3"

      zpool create -o ashift=12 \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O dnodesize=auto \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      -O mountpoint=/ \
      -R /mnt \
      rpool \
      "${TARGET_DISK}-part4"
}

main() {
    check_root

    dependencies

    select_disk

    format_disk

    create_partitions

    create_zfs_pools
}

main