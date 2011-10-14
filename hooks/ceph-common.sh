#!/bin/sh

send_ssh_key() {
    if [ ! -f "/root/.ssh/id_rsa" ] ; then
        ssh-keygen -q -N '' -t rsa -b 2048 -f /root/.ssh/id_rsa
    fi
    relation-set ssh-key="`cat /root/.ssh/id_rsa.pub`"
}

swap_config() {
    old=$1
    new=$2
    [ -n "$old" ] || return
    [ -n "$new" ] || return
    [ ! -e $old ] || mv -f $old $old.last
    mv $new $old
}

append_config() {
    from=$1
    to=$2
    if [ -f "$from" ] ; then
        cat $from >> $to
    fi
}

generate_osd_conf() {
    new_osd_config=`mktemp /etc/ceph/.osd.conf.partial.XXXXXXXX`
    for unit in $JUJU_UNIT_NAME `relation-list` ; do
        id=`echo $unit | cut -d/ -f2` 
        if [ "$unit" = "$JUJU_UNIT_NAME" ] ; then
            host=$HOSTNAME
        else
            host=`relation-get hostname $unit`
        fi
        cat >> $new_osd_config <<EOF

[osd.$id]
    host = $host

EOF
    done

    myid=`echo $JUJU_UNIT_NAME | cut -d/ -f2`
    mkdir -p /mnt/osd$myid
    swap_config /etc/ceph/osd.conf.partial $new_osd_config
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
    # XXX We cannot change the mount options in an LXC contaienr.. *HRM*
    [ -n "`which lxc-is-container`" ] || mount /mnt -o remount,xattr_user
}

generate_mds_conf() {
    new_mds_config=`mktemp /etc/ceph/.mon.conf.partial.XXXXXX`
    for unit in $JUJU_UNIT_NAME `relation-list` ; do
        id=`echo $unit | cut -d/ -f2`
        if [ "$unit" = "$JUJU_UNIT_NAME" ] ; then
            host=$HOSTNAME
        else
            host=`relation-get hostname $unit`
        fi
        cat >> $new_mds_config <<EOF

[mds.$id]
    host=$host

EOF
    done
    swap_config /etc/ceph/mds.conf.partial $new_mds_config
}

generate_mon_conf() {
    new_mon_config=`mktemp /etc/ceph/.mon.conf.partial.XXXXXX`
    for unit in $JUJU_UNIT_NAME `relation-list` ; do
        id=`echo $unit | cut -d/ -f2`
        if [ "$unit" = "$JUJU_UNIT_NAME" ] ; then
            host=$HOSTNAME
            addr=`unit-get private-address`
        else
            host=`relation-get hostname $unit`
            addr=`relation-get private-address $unit`
        fi
        if echo $addr | grep "\d\.\d\.\d\.\d" ; then
            echo $addr is already an ipv4 address
        else
            addr=`dig $addr +short`
        fi
        cat >> $new_mon_config <<EOF

[mon.$id]
    host=$host
    mon addr = $addr

EOF
    done

    myid=`echo $JUJU_UNIT_NAME | cut -d/ -f2`
    mkdir -p /mnt/mon$myid
    swap_config /etc/ceph/mon.conf.partial $new_mon_config
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
    

