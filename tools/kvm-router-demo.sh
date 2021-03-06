#!/bin/sh



############
#
#
#  H1 --> h1-e0 : h1-e1
#	|-br-h1-r1-| 
#		r1-e0 <-- R1 --> r1-e1 
#			|-br-r1-r2-| 
#		r2-e1 <-- R2 --> r2-e0 
#	|-br-r2-h2-| 
#  h2-e1 : h2-e0 <-- H2
#

BRCTL=brctl
IP=ip
KVM=kvm

SCREEN=demo
BRIDGES="br-h1-r1 br-r1-r2 br-r2-h2"
INTERFACES="h1-eth1 h2-eth1 $BRIDGES"
NAMESPACES="h1 h2 r1 r2"
PREFIX="10.99"
SRC_KVM_IMG=onl-i386.img
#KVM_OPTS="-m 1024 -cdrom loader-i386.iso -boot d -nographic -hda onl-i386.img"
KVM_OPTS="-m 1024 -cdrom loader-i386.iso -boot d -nographic -chardev pty,id=pty0 "

do_setup() {

   for bridge in $BRIDGES; do 
      echo Adding bridge $bridge
      $BRCTL addbr $bridge || die "$BRCTL addbr $bridge Failed"
   done

   echo Adding Namespaces
   for ns in $NAMESPACES ; do 
       echo Creating namespace $ns
       $IP netns add $ns
   done
	
   echo Adding h1 interfaces
   $IP link add dev h1-eth0 type veth peer name h1-eth1
   $BRCTL addif br-h1-r1 h1-eth1 || die "$BRCTL addif br-h1-r1 h1-eth1"
   $IP link set dev h1-eth0 up netns h1
   $IP netns exec h1 $IP addr change ${PREFIX}.1.2 broadcast ${PREFIX}.1.255 dev h1-eth0
   $IP netns exec h1 $IP link set dev lo up
   $IP netns exec h1 $IP route add ${PREFIX}.1.0/24 dev h1-eth0
   $IP netns exec h1 $IP route add default via ${PREFIX}.1.1

    
   echo Adding h2 interfaces
   $IP link add dev h2-eth0 type veth peer name h2-eth1
   $BRCTL addif br-r2-h2 h2-eth1 || die "$BRCTL addif br-h2-r2 h2-eth1"
   $IP link set dev h2-eth0 up netns h2
   $IP netns exec h2 $IP addr change ${PREFIX}.2.2 broadcast ${PREFIX}.2.255 dev h2-eth0
   $IP netns exec h2 $IP link set dev lo up
   $IP netns exec h2 $IP route add ${PREFIX}.2.0/24 dev h2-eth0
   $IP netns exec h2 $IP route add default via ${PREFIX}.2.1

   echo Bringing up all interfaces
   for intf in $INTERFACES ; do 
      $IP link set dev $intf up || die "$IP link set dev $intf up"
   done

   echo Adding bridge interfaces
   $IP addr change ${PREFIX}.1.1 broadcast ${PREFIX}.1.255 dev br-h1-r1 
   $IP route add ${PREFIX}.1.0/24 dev br-h1-r1
   $IP addr change ${PREFIX}.2.1 broadcast ${PREFIX}.2.255 dev br-r2-h2
   $IP route add ${PREFIX}.2.0/24 dev br-r2-h2
   $IP addr change ${PREFIX}.3.1 broadcast ${PREFIX}.3.255 dev br-r1-r2
   $IP route add ${PREFIX}.3.0/24 dev br-r1-r2

   echo Starting ONL image Router1
   screen -S $SCREEN -d -m $KVM $KVM_OPTS \
	-name router1 \
	-vnc :0 \
	-net nic -net user,net=${PREFIX}.14.0/24,hostname=router1 \
	-net nic -net tap,ifname=r1-eth0,script=no,downscript=no \
	-net nic -net tap,ifname=r1-eth1,script=no,downscript=no \
	-hda onl-r1.img 

   echo Starting ONL image Router2
   screen -S $SCREEN -X screen $KVM $KVM_OPTS \
	-name router2 \
	-vnc :1 \
	-net nic -net user,net=${PREFIX}.24.0/24,hostname=router2 \
	-net nic -net tap,ifname=r2-eth0,script=no,downscript=no \
	-net nic -net tap,ifname=r2-eth1,script=no,downscript=no \
	-hda onl-r2.img 

   echo Waiting a bit for KVM to start
   sleep 2

   for intf in r1-eth0 r1-eth1 r2-eth0 r2-eth1 ; do 
	$IP link set dev $intf up
   done
   $BRCTL addif br-h1-r1 r1-eth0 || die "$BRCTL addif br-h1-r1 r1-eth0"
   $BRCTL addif br-r2-h2 r2-eth0 || die "$BRCTL addif br-r2-h2 r2-eth0"
   $BRCTL addif br-r1-r2 r1-eth1 || die "$BRCTL addif br-r1-r2 r1-eth1"
   $BRCTL addif br-r1-r2 r2-eth1 || die "$BRCTL addif br-r1-r2 r2-eth1"
}

do_teardown() {

   echo '*** ' Killing all KVM instances
   killall qemu-system-x86_64

   echo '*** ' Bringing down all interfaces
   for intf in $INTERFACES ; do 
      $IP link set dev $intf down
   done
   for bridge in $BRIDGES; do 
      echo '*** ' Removing bridge $bridge
      $BRCTL delbr $bridge 
   done

   echo '*** ' Removing Namespaces
   for ns in $NAMESPACES ; do 
       echo '*** ' Removing namespace $ns
       $IP netns delete $ns
   done

   echo '*** ' Removing screen \'$SCREEN\'
   screen -wipe $SCREEN
	

   # Not needed anymore
   #echo Removing h1 interfaces
   #$IP link del dev h1-eth0 type veth peer name h1-eth1
   #echo Removing h2 interfaces
   #$IP link del dev h2-eth0 type veth peer name h2-eth1

}

do_show () {
    echo '*** ' Bridges:
    $BRCTL show
    echo '*** ' Namespaces:
    $IP netns 
    echo '*** ' Interfaces:
    for intf in $INTERFACES ; do
       $IP addr show $intf
    done
    echo '*** ' KVM instances:
    pgrep qemu-system-x86_6
    echo '*** ' Screen instances
    screen -ls
}

die () {
   echo '******' FAILED COMMMAND $1 >&2
   echo Dying.... >&2
   exit 1
}

do_usage() {
   echo "Usage: $0 <-setup|-teardown|-show|-shell h1 h2 r1 r2>" >&2
   exit 1
}


if [ "X$1" = "X" ] ; then
   do_usage
fi

if [ `id -u` != 0 ] ; then
   die "You need to run this as root"
fi

case $1 in 
   -setup)
	do_setup ;;
   -teardown)
	do_teardown ;;
   -show)
	do_show ;;
   *)
	do_usage ;;
esac
