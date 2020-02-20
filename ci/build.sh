#!/bin/bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

readonly PROGNAME=$(basename "$0")
readonly PROGDIR=$(readlink -m "$(dirname "$0")")
readonly ARGS=("$@")

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Script must be executed with root privileges"
        exit 1
    fi
}

force_mount() {
    local args=("$@")
    local mount_dir="${args[-1]}"
    
    if grep -qs "$mount_dir " /proc/mounts; then
        umount -q "$mount_dir"
    fi
    mount "${args[@]}"
}

mount_iso() {
    local iso="$1"
    local dir="$2"

    force_mount --options loop "$iso" "$dir"
}

copy_iso_files() {
    local iso_dir="$1"
    local target_dir="$2"

    rsync --delete --archive \
        --exclude="md5sum.txt" \
        --exclude="/casper/filesystem.squashfs" \
        --exclude="/casper/filesystem.squashfs.gpg" \
        --progress "$iso_dir" "$target_dir"
}

unsquash_root_fs() {
    local squash_file="$1"
    local target="$2"

    unsquashfs -force -dest "$target" "$squash_file"
}

prepare_for_chroot() {
    local base_dir="$1"

    force_mount --bind            /dev    "$base_dir/dev"
    force_mount --bind            /run    "$base_dir/run"
    force_mount --types proc      /proc   "$base_dir/proc"
    force_mount --types sysfs     sys     "$base_dir/sys"
    force_mount --types devpts    pts     "$base_dir/dev/pts"
}

copy_install_files() {
    local source="$1"
    local target="$2"

    rsync --archive --info=progress2 "$source" "$target"
}

umount_all() {
    local mount_dir="$1"
    local chroot_dir="$2"

    umount -q "$mount_dir"
    umount -q "$chroot_dir/dev/pts"
    umount -q "$chroot_dir/sys"
    umount -q "$chroot_dir/proc"
    umount -q "$chroot_dir/run"
    umount -q "$chroot_dir/dev"
}

usage() {
    # Do NOT replace TAB characters with spaces in the following block
    cat <<- EOF
	USAGE
        $PROGNAME [-w <working directory>]
                  [-i <base Ubuntu ISO file path>]

	DESCRIPTION
        Program generates a custom Ubuntu ISO file which embeds the ubuntu-on-zfs install scripts.

	OPTIONS:
        --working-directory, -w     path of the working directory.

        --input-iso, -i             path of the base Ubuntu ISO file.

        --help, -h                  display this help

	EXAMPLES:
        All options specified:
        $PROGNAME --working-directory /tmp/custom-ubuntu \\
                  --input-iso /home/user/download/ubuntu-19.10-desktop-amd64.iso
	EOF
}


cmdline() {
    # Adapted from http://kfirlavi.herokuapp.com/blog/2012/11/14/defensive-bash-programming/
    local arg
    local args
    local option
    local OPTIND
    local OPTARG

    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    # `for arg; do ... done` means exactly the same as `for arg in "$@"; do ...; done`
    for arg; do
        local delim=""
        case "$arg" in
            # Translate --some-long-option to -s (short options)
            --working-directory)
                args="${args}-w "
                ;;
            --input-iso)
                args="${args}-i "
                ;;
            --help)
                args="${args}-h "
                ;;
            # Pass through anything else
            *)
                [[ "${arg:0:1}" == "-" ]] || delim="\""
                args="${args}${delim}${arg}${delim} "
                ;;
        esac
    done

    # Reset the positional parameters to the short options
    eval set -- "$args"

    # Great getopts examples here: https://www.quennec.fr/book/export/html/341
    while getopts ":hw:i:" option; do
        case $option in
        h)
            usage
            exit 0
            ;;
        w)
            readonly WORK_DIR="$OPTARG"
            readonly ISO_MOUNT_DIR="$WORK_DIR/original-iso-mount/"
            readonly CUSTOM_ISO_DIR="$WORK_DIR/custom-live-iso/"
            readonly ROOT_FS="$WORK_DIR/squashfs-root"
            ;;
        i)
            readonly ISO="$OPTARG"
            ;;
        :)
            echo "-$OPTARG: missing argument"
            exit 1
            ;;
        \?)
            echo "-$OPTARG: invalid option"
            exit 1
            ;;
        esac
    done
}


main() {

    check_root

    cmdline "${ARGS[@]}"

    mkdir -p "$ISO_MOUNT_DIR" "$CUSTOM_ISO_DIR" "$ROOT_FS"

    mount_iso "$ISO" "$ISO_MOUNT_DIR"

    copy_iso_files "$ISO_MOUNT_DIR" "$CUSTOM_ISO_DIR"

    unsquash_root_fs "$ISO_MOUNT_DIR/casper/filesystem.squashfs" "$ROOT_FS"

    prepare_for_chroot "$ROOT_FS"

    copy_install_files "$PROGDIR/../scripts/" "$ROOT_FS/usr/local/bin/"

    # TODO

    umount_all "$ISO_MOUNT_DIR" "$ROOT_FS"
}

main