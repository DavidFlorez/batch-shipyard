#!/usr/bin/env bash

set -e
set -o pipefail

DEBIAN_FRONTEND=noninteractive

# constants
gluster_brick_mountpath=/gluster/brick
gluster_brick_location=$gluster_brick_mountpath/brick0
gluster_volname=gv0
ipaddress=$(ip addr list eth0 | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)

# vars
attach_disks=0
rebalance=0
filesystem=
peer_ips=
server_type=
mountpath=
optimize_tcp=0
server_options=
premium_storage=0
raid_level=-1
offset=

# functions
setup_nfs() {
    # amend /etc/exports if needed
    add_exports=0
    set +e
    grep "^${mountpath}" /etc/exports
    if [ $? -ne 0 ]; then
        add_exports=1
    fi
    if [ $add_exports -eq 1 ]; then
        # note that the * address/hostname allow is ok since we block nfs
        # inbound traffic at the network security group except for allowed
        # ip addresses as specified in the fs.json file
        echo "${mountpath} *(rw,sync,root_squash,no_subtree_check,mountpoint=${mountpath})" >> /etc/exports
        systemctl reload nfs-kernel-server.service
        exportfs -v
    fi
    systemctl status nfs-kernel-server.service
    if [ $? -ne 0 ]; then
        set -e
        # attempt to start
        systemctl start nfs-kernel-server.service
    fi
    set -e
}

gluster_peer_probe() {
    echo "Attempting to peer with $1"
    peered=0
    local START=$(date -u +"%s")
    set +e
    while :
    do
        # attempt to ping before peering
        ping -c 2 $1 > /dev/null
        if [ $? -eq 0 ]; then
            gp_info=`gluster peer probe $1`
            if [ $? -eq 0 ]; then
                echo $gp_info
                peered=1
            fi
        fi
        if [ $peered -eq 1 ]; then
            break
        else
            local NOW=$(date -u +"%s")
            local DIFF=$((($NOW-$START)/60))
            # fail after 15 minutes of attempts
            if [ $DIFF -ge 15 ]; then
                echo "Could not probe peer $1"
                exit 1
            fi
            sleep 1
        fi
    done
    set -e
    echo "Peering successful with $1"
}

gluster_poll_for_connections() {
    local numnodes=$1
    local numpeers=$(($numnodes - 1))
    echo "Waiting for $numpeers peers to reach connected state..."
    # get peer info
    set +e
    while :
    do
        local numready=$(gluster peer status | grep -e '^State: Peer in Cluster' | wc -l)
        if [ $numready == $numpeers ]; then
            break
        fi
        sleep 1
    done
    set -e
    echo "$numpeers joined peering"
    # delay to wait for after peer connections
    sleep 5
}

gluster_poll_for_volume() {
    echo "Waiting for gluster volume $1"
    local START=$(date -u +"%s")
    set +e
    while :
    do
        gluster volume info $1
        if [ $? -eq 0 ]; then
            echo $gv_info
            # delay to wait for subvolumes
            sleep 5
            break
        else
            local NOW=$(date -u +"%s")
            local DIFF=$((($NOW-$START)/60))
            # fail after 15 minutes of attempts
            if [ $DIFF -ge 15 ]; then
                echo "Could not connect to gluster volume $1"
                exit 1
            fi
            sleep 2
        fi
    done
    set -e

}

setup_glusterfs() {
    IFS=',' read -ra hosts <<< "$peer_ips"
    # master (first host) performs peering
    if [ ${hosts[0]} == $ipaddress ]; then
        # construct brick locations
        IFS=',' read -ra hosts <<< "$peer_ips"
        bricks=
        for host in "${hosts[@]}"
        do
            bricks+=" $host:$gluster_brick_location"
            # probe peer
            if [ $host != $ipaddress ]; then
                gluster_peer_probe $host
            fi
        done
        # wait for connections
        local numnodes=${#hosts[@]}
        gluster_poll_for_connections $numnodes
        # parse server options in the format voltype,transport,key:value,...
        IFS=',' read -ra so <<< "$server_options"
        local voltype=${so[0],,}
        local volarg=
        if [ $voltype == "replica" ] || [ $voltype == "stripe" ]; then
            volarg="$voltype $numnodes"
        elif [ $voltype != "distributed" ]; then
            # allow custom replica and/or stripe counts
            volarg=$voltype
        fi
        local transport=${so[1],,}
        if [ -z $transport ]; then
            transport="tcp"
        fi
        # create volume
        echo "Creating $voltype gluster volume $gluster_volname ($bricks)"
        gluster volume create $gluster_volname $volarg transport $transport$bricks
        # modify volume properties as per input
        for e in ${so[@]:2}; do
            IFS=':' read -ra kv <<< "$e"
            echo "Setting volume option ${kv[@]}"
            gluster volume set $gluster_volname ${kv[0]} ${kv[1]}
        done
        # start volume
        echo "Starting gluster volume $gluster_volname"
        gluster volume start $gluster_volname
    fi

    # poll for volume created
    gluster_poll_for_volume $gluster_volname

    # add gluster volume to /etc/fstab
    mkdir -p $mountpath
    echo "Adding $mountpath to fstab"
    echo "$ipaddress:$gluster_volname $mountpath glusterfs _netdev,auto 0 2" >> /etc/fstab

    # mount it
    echo "Mounting gluster volume $gluster_volname locally to $mountpath"
    local START=$(date -u +"%s")
    set +e
    while :
    do
        mount $mountpath
        if [ $? -eq 0 ]; then
            break
        else
            local NOW=$(date -u +"%s")
            local DIFF=$((($NOW-$START)/60))
            # fail after 5 minutes of attempts
            if [ $DIFF -ge 5 ]; then
                echo "Could not mount gluster volume $gluster_volume to $mountpath"
                exit 1
            fi
            sleep 1
        fi
    done
    set -e

    # ensure proper permissions on mounted directory
    chmod 1777 $mountpath
}

# begin processing
while getopts "h?abf:i:m:no:pr:s:v:" opt; do
    case "$opt" in
        h|\?)
            echo "shipyard_remotefs_bootstrap.sh parameters"
            echo ""
            echo "-a attach mode"
            echo "-b rebalance filesystem on resize"
            echo "-f [filesystem] filesystem"
            echo "-i [peer IPs] peer IPs"
            echo "-m [mountpoint] mountpoint"
            echo "-n Tune TCP parameters"
            echo "-o [server options] server options"
            echo "-p premium storage disks"
            echo "-r [RAID level] RAID level"
            echo "-s [server type] server type"
            echo "-v [offset] VM offset"
            echo ""
            exit 1
            ;;
        a)
            attach_disks=1
            ;;
        b)
            rebalance=1
            ;;
        f)
            filesystem=${OPTARG,,}
            ;;
        i)
            peer_ips=${OPTARG,,}
            ;;
        m)
            mountpath=$OPTARG
            ;;
        n)
            optimize_tcp=1
            ;;
        o)
            server_options=$OPTARG
            ;;
        p)
            premium_storage=1
            ;;
        r)
            raid_level=$OPTARG
            ;;
        s)
            server_type=${OPTARG,,}
            ;;
        v)
            offset=1
            ;;
    esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift

# TODO required parameter checks

echo "Parameters:"
echo "  Attach mode: $attach_disks"
echo "  Rebalance filesystem: $rebalance"
echo "  Filesystem: $filesystem"
echo "  Mountpath: $mountpath"
echo "  Tune TCP parameters: $optimize_tcp"
echo "  Premium storage: $premium_storage"
echo "  RAID level: $raid_level"
echo "  Server type: $server_type"
echo "  VM offset: $offset"
echo "  Peer IPs: $peer_ips"
echo "  IP address of VM: $ipaddress"

# first start prep
if [ $attach_disks -eq 0 ]; then
    # always copy scripts to well known location
    mkdir -p /opt/batch-shipyard
    cp shipyard_remotefs_*.sh /opt/batch-shipyard
    # optimize network TCP settings
    if [ $optimize_tcp -eq 1 ]; then
        sysctlfile=/etc/sysctl.d/60-azure-batch-shipyard-remotefs.conf
        if [ ! -e $sysctlfile ] || [ ! -s $sysctlfile ]; then
cat > $sysctlfile << EOF
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=30000
net.ipv4.tcp_max_syn_backlog=80960
net.ipv4.tcp_mem=16777216 16777216 16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_abort_on_overflow=1
net.ipv4.route.flush=1
EOF
        fi
        # reload settings
        service procps reload
    fi
    # install required server_type software
    apt-get update
    if [ $server_type == "nfs" ]; then
        apt-get install -y --no-install-recommends nfs-kernel-server
        # patch buggy nfs-mountd.service unit file
        # https://bugs.launchpad.net/ubuntu/+source/nfs-utils/+bug/1590799
        set +e
        grep "^After=network.target local-fs.target" /lib/systemd/system/nfs-mountd.service
        if [ $? -eq 0 ]; then
            set -e
            sed -i -e "s/^After=network.target local-fs.target/After=rpcbind.target/g" /lib/systemd/system/nfs-mountd.service
        fi
        set -e
        # reload unit files
        systemctl daemon-reload
        # enable and start nfs server
        systemctl enable nfs-kernel-server.service
        # start service if not started
        set +e
        systemctl status nfs-kernel-server.service
        if [ $? -ne 0 ]; then
            set -e
            systemctl start nfs-kernel-server.service
        fi
        set -e
    elif [ $server_type == "glusterfs" ]; then
        apt-get install -y -q --no-install-recommends glusterfs-server
        # reload unit files
        systemctl daemon-reload
        # enable and start nfs server
        systemctl enable glusterfs-server
        # start service if not started
        set +e
        systemctl status glusterfs-server
        if [ $? -ne 0 ]; then
            set -e
            systemctl start glusterfs-server
        fi
        set -e
    else
        echo "server_type $server_type not supported."
        exit 1
    fi
fi

# get all data disks
declare -a data_disks
all_disks=($(lsblk -l -d -n -p -I 8 -o NAME))
for disk in "${all_disks[@]}"; do
    # ignore os and ephemeral disks
	if [ $disk != "/dev/sda" ] && [ $disk != "/dev/sdb" ]; then
        data_disks=("${data_disks[@]}" "$disk")
    fi
done
unset all_disks
numdisks=${#data_disks[@]}
echo "found $numdisks data disks: ${data_disks[@]}"

# check if data disks are already partitioned
declare -a skipped_part
for disk in "${data_disks[@]}"; do
    part1=$(partprobe -d -s $disk | cut -d' ' -f4)
    if [ -z $part1 ]; then
        echo "$disk: partition 1 not found. Partitioning $disk."
        echo -e "n\np\n1\n\n\nw" | fdisk $disk
    else
        echo "$disk: partition 1 found. Skipping partitioning."
        skipped_part=("${skipped_part[@]}" "$disk")
    fi
done

# set format target
target=
target_uuid=
format_target=1
# check if there was only one skipped disk during partitioning
if [ ${#skipped_part[@]} -eq $numdisks ] && [ $numdisks -eq 1 ]; then
    target=${skipped_part[0]}
    read target_uuid target_fs < <(blkid -u filesystem $target | awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
    if [ ! -z $target_fs ]; then
        format_target=0
    fi
fi

# check if disks are already in raid set
raid_resized=0
if [ $raid_level -ge 0 ]; then
    format_target=0
    md_preexist=0
    if [ $filesystem == "btrfs" ]; then
        if [ $raid_level -ne 0 ]; then
            echo "btrfs with non-RAID 0 is not supported."
            exit 1
        fi
    else
        # find any pre-existing targets
        set +e
        mdadm --detail --scan
        if [ $? -eq 0 ]; then
            target=($(find /dev/md* -maxdepth 0 -type b))
            if [ ${#target[@]} -ne 0 ]; then
                target=${target[0]}
                md_preexist=1
                echo "Existing array found: $target"
                # refresh target uuid to md target
                read target_uuid < <(blkid ${target} | awk -F "[= ]" '{print $3}' | sed 's/\"//g')
            else
                echo "No pre-existing md target could be found"
            fi
        fi
        set -e
        if [ -z $target ]; then
            target=/dev/md0
            echo "Setting default target: $target"
        fi
    fi
    declare -a raid_array
    declare -a all_raid_disks
    set +e
    for disk in "${data_disks[@]}"; do
        if [ $filesystem == "btrfs" ]; then
            btrfs device scan "${disk}1"
        else
            mdadm --examine "${disk}1"
        fi
        if [ $? -ne 0 ]; then
            raid_array=("${raid_array[@]}" "${disk}1")
        fi
        all_raid_disks=("${all_raid_disks[@]}" "${disk}1")
    done
    set -e
    no_raid_count=${#raid_array[@]}
    # take action depending upon no raid count
    if [ $no_raid_count -eq 0 ]; then
        echo "No disks require RAID setup"
    elif [ $no_raid_count -eq $numdisks ]; then
        echo "$numdisks data disks require RAID setup: ${raid_array[@]}"
        if [ $filesystem == "btrfs" ]; then
            if [ $raid_level -eq 0 ]; then
                mkfs.btrfs -d raid0 ${raid_array[@]}
            else
                mkfs.btrfs -m raid${raid_level} ${raid_array[@]}
            fi
        else
            set +e
            # first check if this is a pre-existing array
            mdadm_detail=$(mdadm --detail --scan)
            if [ -z $mdadm_detail ]; then
                set -e
                mdadm --create --verbose $target --level=$raid_level --raid-devices=$numdisks ${raid_array[@]}
                format_target=1
            else
                if [ $md_preexist -eq 0 ]; then
                    echo "Could not determine pre-existing md target"
                    exit 1
                fi
                echo "Not creating a new array since pre-exsting md target found: $target"
            fi
            set -e
        fi
    else
        echo "Mismatch of non-RAID disks $no_raid_count to total disks $numdisks."
        if [ $raid_level -ne 0 ]; then
            echo "Cannot resize with RAID level of $raid_level."
            exit 1
        fi
        if [ $filesystem == "btrfs" ]; then
            # add new block devices first
            echo "Adding devices ${raid_array[@]} to $mountpath"
            btrfs device add ${raid_array[@]} $mountpath
            # resize btrfs volume
            echo "Resizing filesystem at $mountpath."
            btrfs filesystem resize max $mountpath
            # rebalance data and metadata across all devices
            if [ $rebalance -eq 1 ]; then
                echo "Rebalancing btrfs on $mountpath."
                btrfs filesystem balance $mountpath
                echo "Rebalance of btrfs on $mountpath complete."
            fi
            raid_resized=0
        else
            # add new block device first
            echo "Adding devices ${raid_array[@]} to $target"
            mdadm --add $target ${raid_array[@]}
            # grow the array
            echo "Growing array $target to a total of $numdisks devices"
            mdadm --grow --raid-devices=$numdisks $target
            raid_resized=1
        fi
    fi
    # dump diagnostic info
    if [ $filesystem == "btrfs" ]; then
        btrfs filesystem show
    else
        cat /proc/mdstat
        mdadm --detail $target
    fi
    # get uuid of first disk as target uuid if not populated
    if [ -z $target_uuid ]; then
        read target_uuid < <(blkid ${all_raid_disks[0]} | awk -F "[= ]" '{print $3}' | sed 's/\"//g')
    fi
fi

# create filesystem on target device
if [ $format_target -eq 1 ]; then
    if [ -z $target ]; then
        echo "Target not specified for format"
        exit 1
    fi
    echo "Creating filesystem on $target."
    if [ $filesystem == "btrfs" ]; then
        mkfs.btrfs $target
    elif [[ $filesystem == ext* ]]; then
        mkfs.${filesystem} -m 0 $target
    else
        echo "Unknown filesystem: $filesystem"
        exit 1
    fi
    # refresh target uuid
    read target_uuid < <(blkid ${target} | awk -F "[= ]" '{print $3}' | sed 's/\"//g')
fi

# mount filesystem
if [ $attach_disks -eq 0 ]; then
    # redirect mountpath if gluster for bricks
    saved_mp=$mountpath
    if [ $server_type == "glusterfs" ]; then
        mountpath=$gluster_brick_mountpath
    fi
    # check if filesystem is mounted (active array)
    mounted=0
    set +e
    mountpoint -q $mountpath
    if [ $? -eq 0 ]; then
        mounted=1
    fi
    set -e
    # add fstab entry and mount
    if [ $mounted -eq 0 ]; then
        if [ -z $target_uuid ]; then
            echo "Target UUID not populated!"
            exit 1
        fi
        # check if fstab entry exists
        add_fstab=0
        set +e
        grep "^UUID=${target_uuid}" /etc/fstab
        if [ $? -ne 0 ]; then
            add_fstab=1
        fi
        set -e
        # add fstab entry
        if [ $add_fstab -eq 1 ]; then
            echo "Adding $target_uuid to mountpoint $mountpath to /etc/fstab"
            if [ $premium_storage -eq 1 ]; then
                # disable barriers due to RO cache
                if [ $filesystem == "btrfs" ]; then
                    mo=",nobarrier"
                else
                    mo=",barrier=0"
                fi
            else
                # enable discard to save cost on standard storage
                mo=",discard"
            fi
            echo "UUID=$target_uuid $mountpath $filesystem defaults,noatime${mo} 0 2" >> /etc/fstab
        fi
        # create mountpath
        mkdir -p $mountpath
        # mount
        mount $mountpath
        if [ $server_type == "nfs" ]; then
            # ensure proper permissions
            chmod 1777 $mountpath
        elif [ $server_type == "glusterfs" ]; then
            # create the brick location
            mkdir -p $gluster_brick_location
        fi
    fi
    # log mount
    mount | grep $mountpath
    # restore mountpath
    mountpath=$saved_mp
    unset saved_mp
fi


# grow underlying filesystem if required
if [ $raid_resized -eq 1 ]; then
    echo "Resizing filesystem at $mountpath."
    if [ $filesystem == "btrfs" ]; then
        btrfs filesystem resize max $mountpath
    elif [[ $filesystem == ext* ]]; then
        resize2fs $mountpath
    else
        echo "Unknown filesystem: $filesystem"
        exit 1
    fi
fi

# set up server_type software
if [ $attach_disks -eq 0 ]; then
    if [ $server_type == "nfs" ]; then
        setup_nfs
    elif [ $server_type == "glusterfs" ]; then
        setup_glusterfs
    else
        echo "server_type $server_type not supported."
        exit 1
    fi
fi