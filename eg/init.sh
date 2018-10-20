#!/bin/sh

# See https://wiki.freebsd.org/RootOnZFS/GPTZFSBoot

disk="${disk-ada1}"
zroot="${zroot-tank}"
rootfs="${rootfs-$zroot/ROOT/default}"
altroot="${altroot-/mnt}"
[ ! -z "$no_sudo" -o "$no_sudo" != "no" ] && sudo=sudo

warn () {
    echo $* >&2
}

die () {
    warn $*; exit 1
}

[ ! -c "/dev/$disk" ] && die "can't open $disk"
if [ "$zroot" != "$(echo $rootfs |cut -d/ -f1)" ]; then
    rootfs=$(echo $zroot/$(echo $rootfs |cut -d/ -f2-))
fi

$sudo zpool destroy -f $zroot
$sudo gpart destroy -F $disk

set -ex

$sudo gpart create -s gpt $disk
$sudo gpart add -t freebsd-boot -a 4k -s 512K -l gptboot0 $disk
$sudo gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 $disk

mem=$(sed -n '/^real memory/s/ *= */ /p' /var/run/dmesg.boot |
	  awk '/^real memory/ { print int($3 / 1024^3 + 0.5) }')
$sudo gpart add -t freebsd-swap -a 1m -s ${mem}G -l swap0 $disk
$sudo gpart add -t freebsd-zfs -l zfs0 $disk

# create the pool
id=$(gpart backup $disk | grep freebsd-zfs | cut -wf1)
[ -z "$id" ] && die "can't find freebsd-zfs partition"
$sudo zpool create -f -o altroot=$altroot $zroot ${disk}p$id

# create zfs file system hierarchy
$sudo zfs set compress=on $zroot

# create a boot environment hierarchy
parent=$(echo $rootfs | sed s,/[^/]*'$',,)
if echo $parent | grep -q /; then
    $sudo zfs create -o mountpoint=none $parent
fi
$sudo zfs create -o canmount=noauto -o mountpoint=/ $rootfs

# configure boot environment
$sudo zpool set bootfs=$rootfs $zroot

# create the rest of the filesystems
$sudo zfs create -o mountpoint=/tmp -o exec=on  -o setuid=off $zroot/tmp
$sudo zfs create -o canmount=off -o mountpoint=/usr           $zroot/usr
$sudo zfs create                                              $zroot/usr/home
$sudo zfs create                    -o exec=off -o setuid=off $zroot/usr/src
$sudo zfs create                                              $zroot/usr/obj
$sudo zfs create                                -o setuid=off $zroot/usr/ports
$sudo zfs create                                -o setuid=off $zroot/usr/ports/distfiles
$sudo zfs create                                -o setuid=off $zroot/usr/ports/packages
$sudo zfs create -o canmount=off -o mountpoint=/var           $zroot/var
$sudo zfs create                    -o exec=off -o setuid=off $zroot/var/audit
$sudo zfs create                    -o exec=off -o setuid=off $zroot/var/crash
$sudo zfs create                    -o exec=off -o setuid=off $zroot/var/log
$sudo zfs create -o atime=on        -o exec=off -o setuid=off $zroot/var/mail
$sudo zfs create                    -o exec=on  -o setuid=off $zroot/var/tmp
