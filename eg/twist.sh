#!/bin/sh

zroot="${zroot:-tank}"
rootfs="${rootfs:-$zroot/ROOT/default}"
altroot="${altroot-$(zpool get -H altroot $zroot |cut -f3)}"
[ ! -z "$no_sudo" -o "$no_sudo" != "no" ] && sudo=sudo

warn () {
    echo $* >&2
}

die () {
    warn $*; exit 1
}

if [ "$zroot" != "$(echo $rootfs |cut -d/ -f1)" ]; then
    rootfs=$(echo $zroot/$(echo $rootfs |cut -d/ -f2-))
fi

set -ex
$sudo mount -t zfs $rootfs $altroot

# Installing rc.conf.local ...

domainname="$(hostname -d)"
hostname="$(sudo sysrc -R $altroot -n hostname | cut -d. -f1).$domainname"
ip4_addr="$(drill $hostname | awk '!/^;|^$/{print $5}')"
defaultrouter="$(IFS=.; set -- $ip4_addr; echo $1.$2.$3.1)"

TEMPFILE="$(mktemp)"
cat >"$TEMPFILE"<<EOF
hostname="$hostname"
ifconfig_em0="inet $ip4_addr"
defaultrouter="$defaultrouter"
gateway_enable="NO"
ipv6_enable="NO"
EOF

$sudo install -b -B.bak -m 644 "$TEMPFILE" $altroot/etc/rc.conf.local

rm -f "$TEMPFILE"

$sudo umount $altroot
