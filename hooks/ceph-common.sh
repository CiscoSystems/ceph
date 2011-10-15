#!/bin/sh

send_ssh_key() {
    if [ ! -f "/root/.ssh/id_rsa" ] ; then
        ssh-keygen -q -N '' -t rsa -b 2048 -f /root/.ssh/id_rsa
    fi
    relation-set ssh-key="`cat /root/.ssh/id_rsa.pub`"
}

network_address() {
    addr=$1
    if echo $addr | grep "\d\.\d\.\d\.\d" ; then
        echo $addr
    else
        dig $addr +short|head -n 1
    fi
}

run_any() {
    name=$1
    if [ "`config-get run-$name`" = "yes" ] ; then
        return 0
    else
        return 1
    fi
}

run_mds() {
    run_any mds
}

run_osd() {
    run_any osd
}

run_mon() {
    run_any mon
}

swap_config() {
    old=$1
    new=$2
    if cmp --silent $old $new ; then
        return 1
    else
        [ -n "$old" ] || return
        [ -n "$new" ] || return
        [ ! -e $old ] || mv -f $old $old.last
        mv $new $old
    fi
    return 0
}

append_config() {
    from=$1
    to=$2
    if [ -f "$from" ] ; then
        cat $from >> $to
    fi
}

generate_osd_conf() {
    name=$1
    additional=$2
    new_osd_config=`mktemp /etc/ceph/.$name.conf.partial.XXXXXXXX`
    if [ -n "$additional" ] ; then
        id=${additional#*/}
        do_osd_template $id $HOSTNAME >> $new_osd_config
        mkdir -p /mnt/osd$id
    else
        for unit in $additional `relation-list` ; do
            id=${unit#*/}
            host=`relation-get hostname $unit`
            do_osd_template $id $host >> $new_osd_config
        done
    fi

    swap_config /etc/ceph/$name.conf.partial $new_osd_config
    # XXX We cannot change the mount options in an LXC contaienr.. *HRM*
    [ -n "`which lxc-is-container`" ] || mount /mnt -o remount,xattr_user
}

# XXX
# The following is really hard to get right, so commented out for now.
# We need to make sure the datadir has xattrs.. Probably better to
# make an explicit mount once juju can model our block devs a little
# more clearly.
#    augtool <<EOF
#    defnode mnt '/files/etc/fstab/*[file ="/mnt"]'
#    ins opt before \$mnt/opt
#    set \$mnt/opt[1] xattr_user
#    save
#EOF

do_osd_template() {
    osd_id=$1
    osd_host=$2
        cat <<EOF

[osd.$osd_id]
    host = $osd_host

EOF
}

generate_mds_conf() {
    name=$1
    additional=$2
    new_mds_config=`mktemp /etc/ceph/.$name.conf.partial.XXXXXX`
    if [ -n "$additional" ] ; then
        id=${additional#*/}
        do_mds_template $id $HOSTNAME >> $new_mds_config
    else
        for unit in $additional `relation-list` ; do
            id=${unit#*/}
            host=`relation-get hostname $unit`
            do_mds_template $id $host >> $new_mds_config
        done
    fi
    swap_config /etc/ceph/$name.conf.partial $new_mds_config
}

do_mds_template() {
    mds_id=$1
    mds_host=$2
        cat <<EOF

[mds.$mds_id]
    host=$mds_host

EOF
}

i_am_leader() {
    units_file=`mktemp /tmp/units.XXXXXXX`
    relation-list > $units_file
    echo $JUJU_UNIT_NAME >> $units_file
    leader=`sort $units_file|head -n 1`
    rm -f $units_file
    if [ "$JUJU_UNIT_NAME" = "$leader" ] ; then
        return 0
    else
        return 1
    fi
}

have_monmap() {
    if i_am_leader ; then
        myid=${JUJU_UNIT_NAME#*/}
        if [ ! -d /etc/ceph/prepared-monmap ] ; then
            mkcephfs -c /etc/ceph/ceph.conf --prepare-monmap -d /etc/ceph/prepared-monmap
        fi
    else
        if [ ! -d /etc/ceph/prepared-monmap ] ; then
            return 1
        fi
    fi
    return 0
}

bootstrap_mon() {
    # Chicken and egg, need to make sure one mon is up
    [ ! -f /etc/ceph/mon.added ] || return 0
    if ! (
        mkcephfs --prepare-monmap -d /etc/ceph/prepared-monmap
        mkcephfs --prepare-mon -d /etc/ceph/prepared-mon
        mkcephfs --init-local-daemons mon -d /etc/ceph/prepared-mon
        service ceph start
    ) ; then
        touch /etc/ceph/mon.added
    fi
    return 0
}

add_mon() {
    if i_am_leader ; then
        id=${JUJU_REMOTE_UNIT#*/}
        ip=`relation-get private-address`
        ip=`network_address $ip`
        ceph mon add $id $ip:6789
        rsync -av 
    fi
}

init_osd() {
    [ ! -f /etc/ceph/initialized.osd ] || return
    if have_monmap ; then
        mkcephfs --init-local-daemons osd -d /etc/ceph/prepared-monmap
        touch /etc/ceph/initialized.osd
    fi
}

init_mds() {
    [ ! -f /etc/ceph/initialized.mds ] || return
    if have_monmap ; then
        mkcephfs --init-local-daemons mds -d /etc/ceph/prepared-monmap
        touch /etc/ceph/initialized.mds
    fi
}

generate_mon_conf() {
    name=$1
    additional=$2
    new_mon_config=`mktemp /etc/ceph/.$name.conf.partial.XXXXXX`
    if [ -n "$additional" ] ; then
        myid=`echo $additional | cut -d/ -f2`
        addr=`unit-get private-address`
        do_mon_template $myid $HOSTNAME $addr >> $new_mon_config
        mkdir -p /mnt/mon$myid
    else
        for unit in `relation-list` ; do
            id=${unit#*/}
            host=`relation-get hostname $unit`
            addr=`relation-get private-address $unit`
            addr=`network_address $addr`
            do_mon_template $id $host $addr
        done
    fi

    swap_config /etc/ceph/$name.conf.partial $new_mon_config
}

do_mon_template() {
    mon_id=$1
    mon_host=$2
    mon_addr=$3
    cat <<EOF

[mon.$mon_id]
    host=$mon_host
    mon addr = $mon_addr

EOF
}

save_ssh_key() {
    mkdir -p /etc/ceph/ssh-keys
    unit_name=`echo $JUJU_REMOTE_UNIT|sed -e 's,/,-,g'`
    key=`relation-get ssh-key`
    if [ -n "$key" ] ; then
        echo $key > /etc/ceph/ssh-keys/$unit_name
    fi
}

set_permit_root_login() {
    new_value=$1
    sed -i -e "s/^PermitRootLogin .*$/PermitRootLogin $new_value/" /etc/ssh/sshd_config
    # Make sure we didn't hose the configs
    /usr/sbin/sshd -t
    service ssh reload
}

regen_ssh_config() {
    root_ssh=`config-get root-ssh`
    if [ ! "$root_ssh" = "yes" ] ; then
        rm -f /root/.ssh/authorized_keys
        set_permit_root_login no
        return
    fi
    [ -d /etc/ceph/ssh-keys ] || return
    mkdir -p /root/.ssh
    chmod 600 /root/.ssh
    new_keys=`mktemp /root/.ssh/.new_auth_keys.XXXXXX`
    touch $new_keys
    chmod 600 $new_keys
    for key in `ls /etc/ceph/ssh-keys` ; do
        cat /etc/ceph/ssh-keys/$key >> $new_keys
    done
    swap_config /root/.ssh/authorized_keys $new_keys
    set_permit_root_login yes
}

regen_rados_config() {
    rados_port=`config-get rados-port`
    if [ "$rados_port" = "0" ] ; then
        service lighttpd stop || :
        rm -f /etc/lighttpd/lighttpd.conf
        return
    fi
    new_lighttpd=`mktemp /etc/lighttpd/.new.config.XXXXX`
    cat > $new_lighttpd <<EOF
server.modules              = (
            "mod_access",
            "mod_fastcgi",
            "mod_accesslog",
)
server.port = `config-get rados-port`

server.document-root       = "/var/www/"

static-file.exclude-extensions = ( ".php", ".pl", ".fcgi" )

debug.log-request-handling = "enable"

fastcgi.debug = 1
fastcgi.server = ( "/" =>
        -    (( "socket" => "/tmp/php-fastcgi.socket",
                -        "bin-path" => "/var/www/s3gw.fcgi",
                -        "check-local" => "disable",
                -        "max-procs" => 1,
                -    ))
        -  )
server.reject-expect-100-with-417 = "disable"
EOF
    swap_config /etc/lighttpd/lighttpd.conf $new_lighttpd
    service lighttpd stop || :
    service lighttpd start
}
    

