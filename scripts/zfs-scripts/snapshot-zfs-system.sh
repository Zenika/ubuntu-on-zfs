#! /bin/bash

set -e

# Taken from https://www.cyberciti.biz/tips/bash-shell-parameter-substitution-2.html
snapshot_name=${1:-current}

# Inspired from https://www.computerhope.com/unix/bash/mapfile.htm
mapfile -s 1 -t snapshots < <(zfs list -t snapshot -o name)
declare -A snapshot_exist
# Lets' make an associative array from $snapshots, to check later if a given snapshot exist
for snapshot in "${snapshots[@]}"
do
	snapshot_exist[$snapshot]=1
done

for dataset in "bpool/BOOT/ubuntu" "rpool/ROOT/ubuntu"
do 
	if [ "${snapshot_exist["$dataset@$snapshot_name"]}" ]
	then
		echo "Destroying previous snapshot \""$dataset@$snapshot_name"\"…"
		zfs destroy "$dataset@$snapshot_name"
	fi
	echo "Creating new snapshot \""$dataset@$snapshot_name"\"…"
	zfs snapshot "$dataset@$snapshot_name"
done