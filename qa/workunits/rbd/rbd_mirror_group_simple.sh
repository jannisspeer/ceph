#!/usr/bin/env bash
#
# rbd_mirror_group_simple.sh
#
# This script has a set of tests that should pass when run.
# It may repeat some of the tests from rbd_mirror_group.sh, but only those that are known to work
# It has a number of extra tests that imclude multiple images in a group
#
# shellcheck disable=SC2034  # Don't warn about unused variables and functions
# shellcheck disable=SC2317  # Don't warn about unreachable commands


export RBD_MIRROR_NOCLEANUP=1
export RBD_MIRROR_TEMDIR=/tmp/tmp.rbd_mirror
export RBD_MIRROR_SHOW_CMD=1
export RBD_MIRROR_MODE=snapshot

group0=test-group0
group1=test-group1
pool0=mirror
pool1=mirror_parent
image_prefix=test-image

# save and clear the cli args (can't call rbd_mirror_helpers with these defined)
args=("$@")
set --

. $(dirname $0)/rbd_mirror_helpers.sh

# create group with images then enable mirroring.  Remove group without disabling mirroring
declare -a test_create_group_with_images_then_mirror_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 'false')
# create group with images then enable mirroring.  Disable mirroring then remove group
declare -a test_create_group_with_images_then_mirror_2=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 'true')

test_create_group_with_images_then_mirror_scenarios=2

test_create_group_with_images_then_mirror()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local disable_before_remove=$6

  group_create "${primary_cluster}" "${pool}/${group}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" 5
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" 5

  mirror_group_enable "${primary_cluster}" "${pool}/${group}"

  # rbd group list poolName  (check groupname appears in output list)
  # do this before checking for replay_started because queries directed at the daemon fail with an unhelpful
  # error message before the group appears on the remote cluster
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 5
  check_daemon_running "${secondary_cluster}"

  # ceph --daemon mirror group status groupName
  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 5
  check_daemon_running "${secondary_cluster}"

  # rbd mirror group status groupName
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 5

  check_daemon_running "${secondary_cluster}"
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi
  check_daemon_running "${secondary_cluster}"

  if [ 'false' != "${disable_before_remove}" ]; then
    mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  fi

  group_remove "${primary_cluster}" "${pool}/${group}"
  check_daemon_running "${secondary_cluster}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" 5
}

# add and remove images to/from a mirrored group
declare -a test_mirrored_group_add_and_remove_images_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 5)

test_mirrored_group_add_and_remove_images_scenarios=1

test_mirrored_group_add_and_remove_images()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local group_image_count=$6

  group_create "${primary_cluster}" "${pool}/${group}"
  mirror_group_enable "${primary_cluster}" "${pool}/${group}"

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 0

  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    # check secondary cluster sees 0 images
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 0
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi
  # create another image and populate it with some data
  local image_name="test_image"
  image_create "${primary_cluster}" "${pool}/${image_name}" 
  local io_count=10240
  local io_size=4096
  write_image "${primary_cluster}" "${pool}" "${image_name}" "${io_count}" "${io_size}"

  # add, wait for stable and then remove the image from the group
  group_image_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_name}" 

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' $((1+"${group_image_count}"))
  group_image_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_name}" 

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' $((1+"${group_image_count}"))
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
  fi

  # re-add and immediately remove
  group_image_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_name}" 
  group_image_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_name}" 

  # check that expected number of images exist on secondary  
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  # remove and immediately re-add a different image
  group_image_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}2"
  group_image_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}2" 

  # check that expected number of images exist on secondary  
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  # remove all images from the group
  group_images_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  image_remove "${primary_cluster}" "${pool}/${image_name}"
  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  # check that expected number of images exist on secondary - TODO this should be replaying, but deleting the last image seems to cause 
  # the group to go stopped atm  
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+stopped' 0

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  check_daemon_running "${secondary_cluster}"
}

# create group with images then enable mirroring.  Remove all images from group and check state matches initial empty group state
declare -a test_mirrored_group_remove_all_images_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 2)

test_mirrored_group_remove_all_images_scenarios=1

test_mirrored_group_remove_all_images()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local group_image_count=$6

  group_create "${primary_cluster}" "${pool}/${group}"
  mirror_group_enable "${primary_cluster}" "${pool}/${group}"

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 0
  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 0

  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    # check secondary cluster sees 0 images
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 0
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  # remove all images from the group
  group_images_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    # check secondary cluster sees 0 images
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  # check that expected number of images exist on secondary
  # TODO why is the state "stopped" - a new empty group is in the "replaying" state
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+stopped' 0

  # adding the images back into the group causes it to go back to replaying
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    # check secondary cluster sees 0 images
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+stopped' 0
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi
  
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  # remove all images from the group again
  group_images_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  # check that expected number of images exist on secondary  
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+stopped' 0

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  check_daemon_running "${secondary_cluster}"
}

# create group then enable mirroring before adding images to the group.  Disable mirroring before removing group
declare -a test_create_group_mirror_then_add_images_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 'false')
# create group then enable mirroring before adding images to the group.  Remove group with mirroring enabled
declare -a test_create_group_mirror_then_add_images_2=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 'true')

test_create_group_mirror_then_add_images_scenarios=2

test_create_group_mirror_then_add_images()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local disable_before_remove=$6

  group_create "${primary_cluster}" "${pool}/${group}"
  mirror_group_enable "${primary_cluster}" "${pool}/${group}"

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 0
  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 0
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 0
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  images_create "${primary_cluster}" "${pool}/${image_prefix}" 5
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" 5

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    # check secondary cluster sees 0 images
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 0
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  fi

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 5
  check_daemon_running "${secondary_cluster}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 5
  check_daemon_running "${secondary_cluster}"

  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 5

  check_daemon_running "${secondary_cluster}"
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi
  check_daemon_running "${secondary_cluster}"

  if [ 'false' != "${disable_before_remove}" ]; then
    mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  fi

  group_remove "${primary_cluster}" "${pool}/${group}"
  check_daemon_running "${secondary_cluster}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" 5
}

#test empty group
declare -a test_empty_group_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}")
#test empty group with namespace
declare -a test_empty_group_2=("${CLUSTER2}" "${CLUSTER1}" "${pool0}/${NS1}" "${group0}")

test_empty_group_scenarios=2

test_empty_group()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4

  group_create "${primary_cluster}" "${pool}/${group}"
  mirror_group_enable "${primary_cluster}" "${pool}/${group}"

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 0
  check_daemon_running "${secondary_cluster}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 0
  check_daemon_running "${secondary_cluster}"

  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 0

  check_daemon_running "${secondary_cluster}"
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi
  check_daemon_running "${secondary_cluster}"

  try_cmd "rbd --cluster ${secondary_cluster} group snap list ${pool}/${group}" || :
  try_cmd "rbd --cluster ${primary_cluster} group snap list ${pool}/${group}" || :

  mirror_group_disable "${primary_cluster}" "${pool}/${group}"

  try_cmd "rbd --cluster ${secondary_cluster} group snap list ${pool}/${group}" || :
  try_cmd "rbd --cluster ${primary_cluster} group snap list ${pool}/${group}" || :

  group_remove "${primary_cluster}" "${pool}/${group}"
  check_daemon_running "${secondary_cluster}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"
  check_daemon_running "${secondary_cluster}"
}

# test two empty groups
declare -a test_empty_groups_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${group1}")

test_empty_groups_scenarios=1

test_empty_groups()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group0=$4
  local group1=$5

  group_create "${primary_cluster}" "${pool}/${group0}"
  mirror_group_enable "${primary_cluster}" "${pool}/${group0}"

  wait_for_group_present "${secondary_cluster}" "${pool}" "${group0}" 0
  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group0}" 0
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group0}" 'up+replaying' 0
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group0}" 'down+unknown' 0
  fi

  group_create "${primary_cluster}" "${pool}/${group1}"
  mirror_group_enable "${primary_cluster}" "${pool}/${group1}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group1}" 0
  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group1}" 0

  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group0}" 'up+replaying' 0
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group1}" 'up+replaying' 0
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group0}" 'down+unknown' 0
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group1}" 'down+unknown' 0
  fi

  mirror_group_disable "${primary_cluster}" "${pool}/${group0}"
  mirror_group_disable "${primary_cluster}" "${pool}/${group1}"

  group_remove "${primary_cluster}" "${pool}/${group1}"
  group_remove "${primary_cluster}" "${pool}/${group0}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group1}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group1}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group0}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group0}"
  check_daemon_running "${secondary_cluster}"
}

# add image from a different pool to group and test replay
declare -a test_images_different_pools_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${pool1}" "${group0}" "${image_prefix}")

test_images_different_pools_scenarios=1

# This test is not MVP
test_images_different_pools()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool0=$3
  local pool1=$4
  local group=$5
  local image_prefix=$6

  group_create "${primary_cluster}" "${pool0}/${group}"
  mirror_group_enable "${primary_cluster}" "${pool0}/${group}"

  wait_for_group_present "${secondary_cluster}" "${pool0}" "${group}" 0
  wait_for_group_replay_started "${secondary_cluster}" "${pool0}"/"${group}" 0
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool0}"/"${group}" 'up+replaying' 0
  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool0}"/"${group}" 'down+unknown' 0
  fi

  image_create "${primary_cluster}" "${pool0}/${image_prefix}0"
  group_image_add "${primary_cluster}" "${pool0}/${group}" "${pool0}/${image_prefix}0"
  image_create "${primary_cluster}" "${pool1}/${image_prefix}1" 
  group_image_add "${primary_cluster}" "${pool0}/${group}" "${pool1}/${image_prefix}1" 

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    # check secondary cluster sees 0 images
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool0}"/"${group}" 'up+replaying' 0
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool0}"/"${group}"
  fi

  wait_for_group_present "${secondary_cluster}" "${pool0}" "${group}" 2
  wait_for_group_replay_started "${secondary_cluster}" "${pool0}"/"${group}" 2
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool0}"/"${group}" 'up+replaying' 2

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool0}"/"${group}" 'down+unknown' 0
  fi

  group_remove "${primary_cluster}" "${pool0}/${group}"

  wait_for_group_not_present "${primary_cluster}" "${pool0}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool0}" "${group}"

  image_remove "${primary_cluster}" "${pool0}/${image_prefix}0"
  image_remove "${primary_cluster}" "${pool1}/${image_prefix}1"
}

# create regular group snapshots and test replay
declare -a test_create_group_with_images_then_mirror_with_regular_snapshots_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}")

test_create_group_with_images_then_mirror_with_regular_snapshots_scenarios=1

test_create_group_with_images_then_mirror_with_regular_snapshots()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local snap='regular_snap'

  group_create "${primary_cluster}" "${pool}/${group}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" 5
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" 5

  mirror_group_enable "${primary_cluster}" "${pool}/${group}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 5
  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 5
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 5

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  check_group_snap_doesnt_exist "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_doesnt_exist "${secondary_cluster}" "${pool}/${group}" "${snap}"

  group_snap_create "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_exists "${primary_cluster}" "${pool}/${group}" "${snap}"
  # snap is currently copied to secondary cluster, where it remains in the "incomplete" state, but this is maybe incorrect - see slack thread TODO
  # - should not be copied until mirrored.
  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"

  check_group_snap_exists "${secondary_cluster}" "${pool}/${group}" "${snap}"

  group_snap_remove "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_doesnt_exist "${primary_cluster}" "${pool}/${group}" "${snap}"
  # this next extra mirror_group_snapshot should not be needed - waiting for fix TODO
  mirror_group_snapshot "${primary_cluster}" "${pool}/${group}"
  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  check_group_snap_doesnt_exist "${secondary_cluster}" "${pool}/${group}" "${snap}"

  #TODO DEFECT
  #exit 0
  # if I exit at this point and then
  # - force disable mirroring for the group on the secondary
  # - remove the group on the secondary
  # we end up with snapshots that belong to the group being left lying around.
  # see discussion in slack, might need defect

  #TODO also try taking multiple regular group snapshots and check the behaviour there

  mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" 5
}

# create regular group snapshots before enable mirroring
declare -a test_create_group_with_regular_snapshots_then_mirror_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}")

test_create_group_with_regular_snapshots_then_mirror_scenarios=1

test_create_group_with_regular_snapshots_then_mirror()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local group_image_count=12
  local snap='regular_snap'

  group_create "${primary_cluster}" "${pool}/${group}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  group_snap_create "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_exists "${primary_cluster}" "${pool}/${group}" "${snap}"

  mirror_group_enable "${primary_cluster}" "${pool}/${group}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" "${group_image_count}"
#  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" "${group_image_count}"
#  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  #if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
#    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
#  fi

  check_group_snap_exists "${secondary_cluster}" "${pool}/${group}" "${snap}"
  # TODO this next command fails because the regular snapshot seems to get stuck in the "incomplete" state on the secondary
  # and the mirror group snapshot (taken on mirror enable) never appears on the secondary.
  wait_for_group_synced "${primary_cluster}" "${pool}/${group}"
##  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"

  group_snap_remove "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_doesnt_exist "${primary_cluster}" "${pool}/${group}" "${snap}"
  # this next extra mirror_group_snapshot should not be needed - waiting for fix TODO
  mirror_group_snapshot "${primary_cluster}" "${pool}/${group}"
  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  check_group_snap_doesnt_exist "${secondary_cluster}" "${pool}/${group}" "${snap}"

  mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
}

# add a large image to group and test replay
declare -a test_create_group_with_large_image_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}")

test_create_group_with_large_image_scenarios=1

test_create_group_with_large_image()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool0=$3
  local group=$4
  local image_prefix=$5

  group_create "${primary_cluster}" "${pool0}/${group}"
  image_create "${primary_cluster}" "${pool0}/${image_prefix}"
  group_image_add "${primary_cluster}" "${pool0}/${group}" "${pool0}/${image_prefix}"

  mirror_group_enable "${primary_cluster}" "${pool0}/${group}"
  wait_for_group_present "${secondary_cluster}" "${pool0}" "${group}" 1
  wait_for_group_replay_started "${secondary_cluster}" "${pool0}"/"${group}" 1
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool0}"/"${group}" 'up+replaying' 1

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool0}"/"${group}" 'down+unknown' 0
  fi

  big_image=test-image-big
  image_create "${primary_cluster}" "${pool0}/${big_image}" 4G
  group_image_add "${primary_cluster}" "${pool0}/${group}" "${pool0}/${big_image}"

  write_image "${primary_cluster}" "${pool0}" "${big_image}" 1024 4194304
  local group_snap_id
  mirror_group_snapshot "${primary_cluster}" "${pool0}/${group}" group_snap_id
  wait_for_group_snap_present "${secondary_cluster}" "${pool0}/${group}" "${group_snap_id}"

  # TODO if the sync process could be controlled then we could check that test-image is synced before test-image-big
  # and that the group is only marked as synced once both images have completed their sync
  wait_for_group_snap_sync_complete "${secondary_cluster}" "${pool0}/${group}" "${group_snap_id}"

  # Check all images in the group and confirms that they are synced
  test_group_synced_image_status "${secondary_cluster}" "${pool0}/${group}" "${group_snap_id}" 2

  group_image_remove "${primary_cluster}" "${pool0}/${group}" "${pool0}/${big_image}"

  if [ -n "${RBD_MIRROR_NEW_IMPLICIT_BEHAVIOUR}" ]; then
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool0}"/"${group}" 'up+replaying' 2
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool0}"/"${group}"
  fi

  remove_image_retry "${primary_cluster}" "${pool0}" "${big_image}"

  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool0}/${group}"
  test_images_in_latest_synced_group "${secondary_cluster}" "${pool0}/${group}" 1

  mirror_group_disable "${primary_cluster}" "${pool0}/${group}"
  group_remove "${primary_cluster}" "${pool0}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool0}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool0}" "${group}"

  image_remove "${primary_cluster}" "${pool0}/${image_prefix}"
}

# multiple images in group with io
declare -a test_create_group_with_multiple_images_do_io_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}")

test_create_group_with_multiple_images_do_io_scenarios=1

test_create_group_with_multiple_images_do_io()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5

  group_create "${primary_cluster}" "${pool}/${group}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" 5
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" 5

  mirror_group_enable "${primary_cluster}" "${pool}/${group}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" 5

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" 5
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' 5

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  local io_count=1024
  local io_size=4096

  local loop_instance
  for loop_instance in $(seq 0 $((5-1))); do
    write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done

  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}/${group}"
  test_images_in_latest_synced_group "${secondary_cluster}" "${pool}/${group}" 5

  for loop_instance in $(seq 0 $((5-1))); do
      compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  for loop_instance in $(seq 0 $((5-1))); do
    write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done

  snap='regular_snap'
  group_snap_create "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_exists "${primary_cluster}" "${pool}/${group}" "${snap}"

  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  check_group_snap_exists "${secondary_cluster}" "${pool}/${group}" "${snap}"
  test_images_in_latest_synced_group "${secondary_cluster}" "${pool}/${group}" 5

  for loop_instance in $(seq 0 $((5-1))); do
      compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  group_snap_remove "${primary_cluster}" "${pool}/${group}" "${snap}"
  check_group_snap_doesnt_exist "${primary_cluster}" "${pool}/${group}" "${snap}"
  # this next extra mirror_group_snapshot should not be needed - waiting for fix TODO
  mirror_group_snapshot "${primary_cluster}" "${pool}/${group}"
  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}"/"${group}"
  check_group_snap_doesnt_exist "${secondary_cluster}" "${pool}/${group}" "${snap}"

  for loop_instance in $(seq 0 $((5-1))); do
      compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" 5
}

# multiple images in group with io
declare -a test_stopped_daemon_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}" 3)

test_stopped_daemon_scenarios=1

test_stopped_daemon()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5
  local group_image_count=$6

  check_daemon_running "${secondary_cluster}"

  group_create "${primary_cluster}" "${pool}/${group}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  mirror_group_enable "${primary_cluster}" "${pool}/${group}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" "${group_image_count}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" "${group_image_count}"
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
  wait_for_group_synced "${primary_cluster}" "${pool}"/"${group}"

  local primary_group_snap_id
  get_newest_group_mirror_snapshot_id "${primary_cluster}" "${pool}"/"${group}" primary_group_snap_id
  local secondary_group_snap_id
  get_newest_group_mirror_snapshot_id "${secondary_cluster}" "${pool}"/"${group}" secondary_group_snap_id
  test "${primary_group_snap_id}" = "${secondary_group_snap_id}" ||  { fail "mismatched ids"; return 1; }

  # Add image to synced group (whilst daemon is stopped)
  echo "stopping daemon"
  stop_mirrors "${secondary_cluster}"

  local image_name="test_image"
  image_create "${primary_cluster}" "${pool}/${image_name}" 
  group_image_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_name}" 
  get_newest_group_mirror_snapshot_id "${primary_cluster}" "${pool}"/"${group}" primary_group_snap_id
  test "${primary_group_snap_id}" != "${secondary_group_snap_id}" ||  { fail "matched ids"; return 1; }

  echo "starting daemon"
  start_mirrors "${secondary_cluster}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" $(("${group_image_count}"+1))
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' $(("${group_image_count}"+1))
  wait_for_group_synced "${primary_cluster}" "${pool}"/"${group}"

  get_newest_group_mirror_snapshot_id "${secondary_cluster}" "${pool}"/"${group}" secondary_group_snap_id
  test "${primary_group_snap_id}" = "${secondary_group_snap_id}" ||  { fail "mismatched ids"; return 1; }

  # removed image from synced group (whilst daemon is stopped)
  echo "stopping daemon"
  stop_mirrors "${secondary_cluster}"

  group_image_remove "${primary_cluster}" "${pool}/${group}" "${pool}/${image_name}" 
  get_newest_group_mirror_snapshot_id "${primary_cluster}" "${pool}"/"${group}" primary_group_snap_id
  test "${primary_group_snap_id}" != "${secondary_group_snap_id}" ||  { fail "matched ids"; return 1; }

  echo "starting daemon"
  start_mirrors "${secondary_cluster}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" "${group_image_count}"
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"
  # TODO next command fails because rbd group snap list command fails with -2
  # though group does exist on secondary
  wait_for_group_synced "${primary_cluster}" "${pool}"/"${group}"

  get_newest_group_mirror_snapshot_id "${secondary_cluster}" "${pool}"/"${group}" secondary_group_snap_id
  test "${primary_group_snap_id}" = "${secondary_group_snap_id}" ||  { fail "mismatched ids"; return 1; }

  # TODO test more actions whilst daemon is stopped
  # add image, take snapshot, remove image, take snapshot, restart
  # disable mirroring 
  
  mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
}

# multiple images in group and standalone images too with io
declare -a test_group_and_standalone_images_do_io_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}")

test_group_and_standalone_images_do_io_scenarios=1

test_group_and_standalone_images_do_io()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group=$4
  local image_prefix=$5

  local standalone_image_prefix=standalone-image
  local standalone_image_count=4
  local group_image_count=2

  images_create "${primary_cluster}" "${pool}/${standalone_image_prefix}" "${standalone_image_count}"

  group_create "${primary_cluster}" "${pool}/${group}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}" "${group_image_count}"

  mirror_group_enable "${primary_cluster}" "${pool}/${group}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group}" "${group_image_count}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group}" "${group_image_count}"
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group}" 'up+replaying' "${group_image_count}"

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group}" 'down+unknown' 0
  fi

  # enable mirroring for standalone images
  local loop_instance
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    enable_mirror "${primary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    wait_for_image_replay_started  "${secondary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    wait_for_replay_complete "${secondary_cluster}" "${primary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    wait_for_replaying_status_in_pool_dir "${secondary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    compare_images "${secondary_cluster}" "${primary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
  done

  local io_count=1024
  local io_size=4096

  # write to all of the images
  for loop_instance in $(seq 0 $(("${group_image_count}"-1))); do
    write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    write_image "${primary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done

  # snapshot the group
  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}/${group}"
  test_images_in_latest_synced_group "${secondary_cluster}" "${pool}/${group}" "${group_image_count}"

  for loop_instance in $(seq 0 $(("${group_image_count}"-1))); do
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  # snapshot the individual images too, wait for sync and compare
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    mirror_image_snapshot "${primary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    wait_for_snapshot_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
  done

  # do more IO
  for loop_instance in $(seq 0 $(("${group_image_count}"-1))); do
    write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    write_image "${primary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done

  # Snapshot the group and images.  Sync both in parallel
  local group_snap_id
  mirror_group_snapshot "${primary_cluster}" "${pool}/${group}" group_snap_id
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    mirror_image_snapshot "${primary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}"
  done

  wait_for_group_snap_sync_complete "${secondary_cluster}" "${pool}/${group}" "${group_snap_id}"
  for loop_instance in $(seq 0 $(("${group_image_count}"-1))); do
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    wait_for_snapshot_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
  done

  mirror_group_disable "${primary_cluster}" "${pool}/${group}"
  group_remove "${primary_cluster}" "${pool}/${group}"
  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group}"

  # re-check images
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${standalone_image_prefix}${loop_instance}"
  done

  # disable mirroring for standalone images
  local loop_instance
  for loop_instance in $(seq 0 $(("${standalone_image_count}"-1))); do
    disable_mirror "${primary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}"
    wait_for_image_present "${secondary_cluster}" "${pool}" "${standalone_image_prefix}${loop_instance}" 'deleted'
  done

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${group_image_count}"
  images_remove "${primary_cluster}" "${pool}/${standalone_image_prefix}" "${standalone_image_count}"
}

# multiple groups with images in each with io
declare -a test_create_multiple_groups_do_io_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${group0}" "${image_prefix}")

test_create_multiple_groups_do_io_scenarios=1

test_create_multiple_groups_do_io()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local group_prefix=$4
  local image_prefix=$5

  local image_count=12
  local group_count=4
  local group_image_count=$(("${image_count}"/"${group_count}"))

  local loop_instance
  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    group_create "${primary_cluster}" "${pool}/${group_prefix}${loop_instance}"
  done

  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${image_count}"

  # evenly spread the images between the groups
  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    group="${group_prefix}"$(("${loop_instance}"%"${group_count}"))
    group_image_add "${primary_cluster}" "${pool}/${group}" "${pool}/${image_prefix}${loop_instance}"
  done

  # enable mirroring for every group
  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    mirror_group_enable "${primary_cluster}" "${pool}/${group_prefix}${loop_instance}"
  done

  # check that every group appears on the secondary
  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    wait_for_group_present "${secondary_cluster}" "${pool}" "${group_prefix}${loop_instance}" "${group_image_count}"
  done

  # check that every group and image are in the correct state on the secondary
  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group_prefix}${loop_instance}" "${group_image_count}"
    wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group_prefix}${loop_instance}" 'up+replaying' "${group_image_count}"

    if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
      wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group_prefix}${loop_instance}" 'down+unknown' 0
    fi
  done  

  local io_count=10240
  local io_size=4096
  local group_to_mirror=0

  # write to every image in one group, mirror group and compare images
  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    group="${group_prefix}"$(("${loop_instance}"%"${group_count}"))
    if [ "${group_to_mirror}" = "${group}" ] ; then
      write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
    fi
  done

  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}/${group_prefix}${group_to_mirror}"

  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  # write to one image in every group, mirror groups and compare images
  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    if [ 0 = $(("${loop_instance}"%"${group_count}")) ] ; then
      write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
    fi
  done

  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}/${group_prefix}${loop_instance}" 
  done  

  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  # write to every image in every group, mirror groups and compare images
  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done

  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}/${group_prefix}${loop_instance}" 
  done  

  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    compare_images "${primary_cluster}" "${secondary_cluster}" "${pool}" "${pool}" "${image_prefix}${loop_instance}"
  done

  # disable and remove all groups
  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    mirror_group_disable "${primary_cluster}" "${pool}/${group_prefix}${loop_instance}"
    group_remove "${primary_cluster}" "${pool}/${group_prefix}${loop_instance}"
  done

  # check all groups have been deleted
  for loop_instance in $(seq 0 $(("${group_count}"-1))); do
    wait_for_group_not_present "${primary_cluster}" "${pool}" "${group_prefix}${loop_instance}"
    wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group_prefix}${loop_instance}"
  done  

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${image_count}"
}

# mirror a group then remove an image from that group and add to a different mirrored group.
declare -a test_image_move_group_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${image_prefix}")

test_image_move_group_scenarios=1

test_image_move_group()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local image_prefix=$4

  local image_count=5
  local group0='group_0'
  local group1='group_1'

  group_create "${primary_cluster}" "${pool}/${group0}"
  group_create "${primary_cluster}" "${pool}/${group1}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group0}" "${pool}/${image_prefix}" "${image_count}"

  mirror_group_enable "${primary_cluster}" "${pool}/${group0}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group0}" "${image_count}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group0}" "${image_count}"
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group0}" 'up+replaying' "${image_count}"

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group0}" 'down+unknown' 0
  fi

  local io_count=10240
  local io_size=4096

  # write to every image in the group, mirror group
  for loop_instance in $(seq 0 $(("${image_count}"-1))); do
    write_image "${primary_cluster}" "${pool}" "${image_prefix}${loop_instance}" "${io_count}" "${io_size}"
  done
  mirror_group_snapshot_and_wait_for_sync_complete "${secondary_cluster}" "${primary_cluster}" "${pool}/${group0}"

  # remove an image from the group and add to a different group
  group_image_remove "${primary_cluster}" "${pool}/${group0}" "${pool}/${image_prefix}4" 
  group_image_add "${primary_cluster}" "${pool}/${group1}" "${pool}/${image_prefix}4"

  mirror_group_enable "${primary_cluster}" "${pool}/${group1}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group1}" 1

  # TODO test fails on next line
  #CEPH_ARGS='--id mirror' ceph --admin-daemon /tmp/tmp.rbd_mirror/rbd-mirror.cluster1-client.mirror.0.asok rbd mirror group status mirror/group_1 --format xml-pretty
  #no valid command found; 1 closest matches:
  #rbd mirror group status mirror/group_0
  #admin_socket: invalid command
  #ERR: rc= 22

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group1}" 1
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group1}" 'up+replaying' 1

  # remove another image from group0 - add to group 1 (add to a group that is already mirror enabled) TODO

  # do the same tests with a group that is syncing (vs synced) TODO

  # set up a chain of moves TODO

  mirror_group_disable "${primary_cluster}" "${pool}/${group0}"
  group_remove "${primary_cluster}" "${pool}/${group0}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group0}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group0}"

  mirror_group_disable "${primary_cluster}" "${pool}/${group1}"
  group_remove "${primary_cluster}" "${pool}/${group1}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group1}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group1}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${image_count}"
}

# test force promote scenarios
declare -a test_force_promote_1=("${CLUSTER2}" "${CLUSTER1}" "${pool0}" "${image_prefix}")

test_force_promote_scenarios=1

test_force_promote()
{
  local primary_cluster=$1
  local secondary_cluster=$2
  local pool=$3
  local image_prefix=$4

  local image_count=5
  local group0='group_0'
  
  group_create "${primary_cluster}" "${pool}/${group0}"
  images_create "${primary_cluster}" "${pool}/${image_prefix}" "${image_count}"
  group_images_add "${primary_cluster}" "${pool}/${group0}" "${pool}/${image_prefix}" "${image_count}"

  mirror_group_enable "${primary_cluster}" "${pool}/${group0}"
  wait_for_group_present "${secondary_cluster}" "${pool}" "${group0}" "${image_count}"

  wait_for_group_replay_started "${secondary_cluster}" "${pool}"/"${group0}" "${image_count}"
  wait_for_group_status_in_pool_dir "${secondary_cluster}" "${pool}"/"${group0}" 'up+replaying' "${image_count}"

  if [ -z "${RBD_MIRROR_USE_RBD_MIRROR}" ]; then
    wait_for_group_status_in_pool_dir "${primary_cluster}" "${pool}"/"${group0}" 'down+unknown' 0
  fi

  # TODO write this test

  mirror_group_disable "${primary_cluster}" "${pool}/${group0}"
  group_remove "${primary_cluster}" "${pool}/${group0}"

  wait_for_group_not_present "${primary_cluster}" "${pool}" "${group0}"
  wait_for_group_not_present "${secondary_cluster}" "${pool}" "${group0}"

  images_remove "${primary_cluster}" "${pool}/${image_prefix}" "${image_count}"
}

run_test()
{
  local test_name=$1
  local test_scenario=$2

  declare -n test_parameters="$test_name"_"$test_scenario"

  testlog "TEST:$test_name scenario:$test_scenario parameters:" "${test_parameters[@]}"
  "$test_name" "${test_parameters[@]}"
}

# exercise all scenarios that are defined for the specified test 
run_test_scenarios()
{
  local test_name=$1

  declare -n test_scenario_count="$test_name"_scenarios

  local loop
  for loop in $(seq 1 $test_scenario_count); do
    run_test $test_name $loop
  done
}

# exercise all scenarios for all tests
run_tests()
{
  run_test_scenarios test_empty_group
  run_test_scenarios test_empty_groups 
  run_test_scenarios test_mirrored_group_remove_all_images
  # This next test is unreliable - image/group ends up in stopped - TODO enable
  # run_test_scenarios test_mirrored_group_add_and_remove_images
  # This next test is unreliable - image ends up in stopped - TODO enable
  # run_test_scenarios test_create_group_mirror_then_add_images
  run_test_scenarios test_create_group_with_images_then_mirror 
  # next test is not MVP - TODO
  # run_test_scenarios test_images_different_pools
  run_test_scenarios test_create_group_with_images_then_mirror_with_regular_snapshots
  run_test_scenarios test_create_group_with_large_image
  run_test_scenarios test_create_group_with_multiple_images_do_io
  # TODO - next test fails
  #run_test_scenarios test_group_and_standalone_images_do_io
  run_test_scenarios test_create_multiple_groups_do_io
  #run_test_scenarios test_stopped_daemon
  #run_test_scenarios test_create_group_with_regular_snapshots_then_mirror
  #run_test_scenarios test_image_move_group
  #run_test_scenarios test_force_promote
}

if [ -n "${RBD_MIRROR_SHOW_CMD}" ]; then
  set -e
else  
  set -ex
fi  

# If the tmpdir and cluster conf file exist then reuse the existing cluster
if [ -d "${RBD_MIRROR_TEMDIR}" ] && [ -f "${RBD_MIRROR_TEMDIR}"'/cluster1.conf' ]
then
  export RBD_MIRROR_USE_EXISTING_CLUSTER=1
fi

setup

# see if we need to (re)start rbd-mirror deamon
pid=$(cat "$(daemon_pid_file "${CLUSTER1}")" 2>/dev/null) || :
if [ -z "${pid}" ]
then
    start_mirrors "${CLUSTER1}"
fi
check_daemon_running "${CLUSTER1}"

# restore the arguments from the cli
set -- "${args[@]}"

# loop count is specified as first argument. default value is 1
loop_count="${1:-1}"
for loop in $(seq 1 "${loop_count}"); do
  echo "run number ${loop} of ${loop_count}"
  if [ "$#" -gt 2 ]
  then
    # second arg is test_name
    # third arg is scenario number
    run_test "$2" "$3"
  else
    run_tests
  fi
done

exit 0
