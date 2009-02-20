#!/bin/bash
#
# Wrapper script for easily running zpios based tests
#

. ./common.sh
PROG=zpios.sh
DATE=`date +%Y%m%d-%H%M%S`

MODULES=(				\
	${MODDIR}/zpios/zpios.ko	\
)

usage() {
cat << EOF
USAGE:
$0 [hvp] <-c config> <-t test>

DESCRIPTION:
        Helper script for easy zpios benchmarking.

OPTIONS:
        -h      Show this message
        -v      Verbose
        -p      Enable profiling
        -c      Zpool configuration
        -t      Zpios test
        -o      Additional zpios options
        -l      Additional zpool options
        -s      Additional zfs options

EOF
}

print_header() {
	echo --------------------- ZPIOS RESULTS ----------------------------
	echo -n "Date: "; date
	echo -n "Kernel: "; uname -r
	dmesg | grep "Loaded Solaris Porting Layer" | tail -n1
	dmesg | grep "Loaded ZFS Filesystem" | tail -n1
	echo
}

print_spl_info() {
	echo --------------------- SPL Tunings ------------------------------
	sysctl -A | grep spl

	if [ -d /sys/module/spl/parameters ]; then
		grep [0-9] /sys/module/spl/parameters/*
	else
		grep [0-9] /sys/module/spl/*
	fi

	echo
}

print_zfs_info() {
	echo --------------------- ZFS Tunings ------------------------------
	sysctl -A | grep zfs

	if [ -d /sys/module/zfs/parameters ]; then
		grep [0-9] /sys/module/zfs/parameters/*
	else
		grep [0-9] /sys/module/zfs/*
	fi

	echo
}

print_stats() {
	echo ---------------------- Statistics -------------------------------
	sysctl -A | grep spl | grep stack_max

	if [ -d /proc/spl/kstat/ ]; then
		if [ -f /proc/spl/kstat/zfs/arcstats ]; then
			echo "* ARC"
			cat /proc/spl/kstat/zfs/arcstats
			echo
		fi

		if [ -f /proc/spl/kstat/zfs/vdev_cache_stats ]; then
			echo "* VDEV Cache"
			cat /proc/spl/kstat/zfs/vdev_cache_stats
			echo
		fi
	fi

	if [ -f /proc/spl/kmem/slab ]; then
		echo "* SPL SLAB"
		cat /proc/spl/kmem/slab
		echo
	fi

	echo
}

check_test() {

	if [ ! -f ${ZPIOS_TEST} ]; then
		local NAME=`basename ${ZPIOS_TEST} .sh`
		ERROR="Unknown test '${NAME}', available tests are:\n"

		for TST in `ls ${TOPDIR}/scripts/zpios-test/`; do
			local NAME=`basename ${TST} .sh`
			ERROR="${ERROR}${NAME}\n"
		done

		return 1
	fi

	return 0
}

zpios_profile_config() {
cat > ${PROFILE_ZPIOS_LOG}/zpios-config.sh << EOF
#
# Zpios Profiling Configuration
#

PROFILE_ZPIOS_LOG=/tmp/zpios/${ZPOOL_CONFIG}+${ZPIOS_TEST_ARG}+${DATE}
PROFILE_ZPIOS_PRE=${TOPDIR}/scripts/zpios-profile/zpios-profile-pre.sh
PROFILE_ZPIOS_POST=${TOPDIR}/scripts/zpios-profile/zpios-profile-post.sh
PROFILE_ZPIOS_USER=${TOPDIR}/scripts/zpios-profile/zpios-profile.sh
PROFILE_ZPIOS_PIDS=${TOPDIR}/scripts/zpios-profile/zpios-profile-pids.sh
PROFILE_ZPIOS_DISK=${TOPDIR}/scripts/zpios-/profile/zpios-profile-disk.sh

OPROFILE_KERNEL_BIN="/boot/vmlinux-`uname -r`"
OPROFILE_KERNEL_BIN_DIR="/lib/modules/`uname -r`/kernel/"
OPROFILE_SPL_BIN_DIR="${SPLBUILD}/module/"
OPROFILE_ZFS_BIN_DIR="${TOPDIR}/module/"

EOF
}

zpios_profile_start() {
	PROFILE_ZPIOS_LOG=/tmp/zpios/${ZPOOL_CONFIG}+${ZPIOS_TEST_ARG}+${DATE}

	mkdir -p ${PROFILE_ZPIOS_LOG}
	zpios_profile_config
	. ${PROFILE_ZPIOS_LOG}/zpios-config.sh

	ZPIOS_OPTIONS="${ZPIOS_OPTIONS} --log=${PROFILE_ZPIOS_LOG}"
	ZPIOS_OPTIONS="${ZPIOS_OPTIONS} --prerun=${PROFILE_ZPIOS_PRE}"
	ZPIOS_OPTIONS="${ZPIOS_OPTIONS} --postrun=${PROFILE_ZPIOS_POST}"

	/usr/bin/opcontrol --init
	/usr/bin/opcontrol --setup --vmlinux=${OPROFILE_KERNEL_BIN}
}

zpios_profile_stop() {
	/usr/bin/opcontrol --shutdown
	/usr/bin/opcontrol --deinit
}

PROFILE=
ZPOOL_CONFIG=zpool-config.sh
ZPIOS_TEST=zpios-test.sh
ZPOOL_NAME=zpios
ZPIOS_OPTIONS=
ZPOOL_OPTIONS=""
ZFS_OPTIONS=""

while getopts 'hvpc:t:o:l:s:' OPTION; do
	case $OPTION in
	h)
		usage
		exit 1
		;;
	v)
		VERBOSE=1
		VERBOSE_FLAG="-v"
		;;
	p)
		PROFILE=1
		;;
	c)
		ZPOOL_CONFIG=${OPTARG}
		;;
	t)
		ZPIOS_TEST_ARG=${OPTARG}
		ZPIOS_TEST=${TOPDIR}/scripts/zpios-test/${OPTARG}.sh
		;;
	o)
		ZPIOS_OPTIONS=${OPTARG}
		;;
	l)	# Passed through to zpool-create.sh 
		ZPOOL_OPTIONS=${OPTARG}
		;;
	s)	# Passed through to zpool-create.sh
		ZFS_OPTIONS=${OPTARG}
		;;
	?)
		usage
		exit
		;;
	esac
done

if [ $(id -u) != 0 ]; then
        die "Must run as root"
fi

# Validate and source your test config
check_test || die "${ERROR}"
. ${ZPIOS_TEST}

# Pull in the zpios test module is not loaded.  If this fails it is
# likely because the full module stack was not yet loaded with zfs.sh
if check_modules; then
	if ! load_modules; then
		die "Run 'zfs.sh' to ensure the full module stack is loaded"
	fi
fi

# Wait for device creation
while [ ! -c /dev/zpios ]; do
	sleep 1
done

if [ ${VERBOSE} ]; then
	print_header
	print_spl_info
	print_zfs_info
fi

# Create the zpool configuration
./zpool-create.sh ${VERBOSE_FLAG} -p ${ZPOOL_NAME} -c ${ZPOOL_CONFIG} \
	-l "${ZPOOL_OPTIONS}" -s "${ZFS_OPTIONS}" || exit 1

if [ ${PROFILE} ]; then
	zpios_profile_start
fi

echo
echo "${DATE}"
zpios_start
zpios_stop

if [ ${PROFILE} ]; then
	zpios_profile_stop
fi

if [ ${VERBOSE} ]; then
	print_stats
fi

# Destroy the zpool configuration
./zpool-create.sh ${VERBOSE_FLAG} -p ${ZPOOL_NAME} -c ${ZPOOL_CONFIG} -d || exit 1

# Unload the test module stack and wait for device removal
unload_modules
while [ -c /dev/zpios ]; do
	sleep 1
done

exit 0
