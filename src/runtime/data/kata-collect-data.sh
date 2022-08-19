#!/usr/bin/env bash
#
# Copyright (c) 2017-2020 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

RUNTIME_VERSION_INFO=$( kata-runtime --version | sed -n 's/^.*: //p' )
read -r VERSION COMMIT <<< $( echo $RUNTIME_VERSION_INFO )

typeset -r project_name="Kata Containers"
typeset -r script_name=${0##*/}
typeset -r runtime_name="kata-runtime"
typeset -r runtime_path=$(command -v "$runtime_name" 2>/dev/null)
typeset -r runtime_snap_name="kata-containers.runtime"
typeset -r runtime_snap_path=$(command -v "$runtime_snap_name" 2>/dev/null)
typeset -r runtime=${runtime_path:-"$runtime_snap_path"}

typeset -r containerd_shim_v2_name="containerd-shim-kata-v2"
typeset -r containerd_shim_v2=$(command -v "$containerd_shim_v2_name" 2>/dev/null)

typeset -r kata_monitor_name="kata-monitor"
typeset -r kata_monitor=$(command -v "$kata_monitor_name" 2>/dev/null)

typeset -r issue_url="https://github.com/kata-containers/kata-containers/issues/new"
typeset -r script_version="$VERSION (commit $COMMIT)"

typeset -r unknown="unknown"

typeset -r osbuilder_file="/var/lib/osbuilder/osbuilder.yaml"

# Maximum number of errors to show for a single system component
# (such as runtime).
PROBLEM_LIMIT=${PROBLEM_LIMIT:-50}

# List of patterns used to detect problems in logfiles.
problem_pattern="("
problem_pattern+="\<abort|"
problem_pattern+="\<bug\>|"
problem_pattern+="\<cannot\>|"
problem_pattern+="\<catastrophic|"
problem_pattern+="\<could not\>|"
problem_pattern+="\<couldn\'t\>|"
problem_pattern+="\<critical|"
problem_pattern+="\<die\>|"
problem_pattern+="\<died\>|"
problem_pattern+="\<does.*not.*exist\>|"
problem_pattern+="\<dying\>|"
problem_pattern+="\<empty\>|"
problem_pattern+="\<erroneous|"
problem_pattern+="\<error|"
problem_pattern+="\<expected\>|"
problem_pattern+="\<fail|"
problem_pattern+="\<fatal|"
problem_pattern+="\<impossible\>|"
problem_pattern+="\<impossibly\>|"
problem_pattern+="\<incorrect|"
problem_pattern+="\<invalid\>|"
problem_pattern+="\<level=\"*error\"* |"
problem_pattern+="\<level=\"*fatal\"* |"
problem_pattern+="\<level=\"*panic\"* |"
problem_pattern+="\<level=\"*warning\"* |"
problem_pattern+="\<missing\>|"
problem_pattern+="\<need\>|"
problem_pattern+="\<no.*such.*file\>|"
problem_pattern+="\<not.*found\>|"
problem_pattern+="\<not.*supported\>|"
problem_pattern+="\<too many\>|"
problem_pattern+="\<unable\>|"
problem_pattern+="\<unavailable\>|"
problem_pattern+="\<unexpected|"
problem_pattern+="\<unknown\>|"
problem_pattern+="\<urgent|"
problem_pattern+="\<warn\>|"
problem_pattern+="\<warning\>|"
problem_pattern+="\<wrong\>"
problem_pattern+=")"

# List of patterns used to exclude messages that are not problems
problem_exclude_pattern="("
problem_exclude_pattern+="\<launching .* with:"
problem_exclude_pattern+=")"

usage()
{
	cat <<EOT
Usage: $script_name [options]

Summary: Collect data about an installation of $project_name.

Description: Run this script as root to obtain a markdown-formatted summary
  of the environment of the $project_name installation. The output of this script
  can be pasted directly into a github issue at the address below:

      $issue_url

Commands:
 show-image-details : outputs the YAML describing the image

Options:

 -h | --help    : show this usage summary.
 -v | --version : show program version.

EOT
}

version()
{
	cat <<EOT
$script_name version $script_version
EOT
}

die()
{
	local msg="$*"
	echo >&2 "ERROR: $script_name: $msg"
	exit 1
}

msg()
{
	local msg="$*"
	echo "$msg"
}

heading()
{
	local name="$*"
	echo -e "\n# $name\n"
}

subheading()
{
	local name="$*"
	echo -e "\n## $name\n"
}

separator()
{
	echo -e '\n---\n'
}

# Create an unfoldable section.
#
# Note: end_section() must be called to terminate the fold.
start_section()
{
	local title="$1"

	cat <<EOT
<details>
<summary>${title}</summary>
<p>

EOT
}

end_section()
{
	cat <<EOT

</p>
</details>
EOT
}

show_header()
{
	start_section "Show <tt>$script_name</tt> details"
}

show_footer()
{
	end_section
}

have_cmd()
{
	local cmd="$1"

	command -v "$cmd" &>/dev/null
	local ret=$?

	if [ $ret -eq 0 ]; then
		msg "Have \`$cmd\`"
	else
		msg "No \`$cmd\`"
	fi

	[ $ret -eq 0 ]
}

have_service()
{
	local service="$1"

	systemctl status "${service}" >/dev/null 2>&1
}

show_quoted_text()
{
	local language="$1"

	shift

	local text="$*"

	echo "\`\`\`${language}"
	echo "$text"
	echo "\`\`\`"
}

run_cmd_and_show_quoted_output()
{
	local language="$1"

	shift

	local cmd="$*"

	local output

	output=$(eval "$cmd" 2>&1)

	start_section "<tt>$cmd</tt>"
	show_quoted_text "${language}" "$output"
	end_section
}

show_runtime_configs()
{
	local title="Runtime config files"
	start_section "$title"

	heading "$title"

	local configs config

	configs=$($runtime --kata-show-default-config-paths)
	if [ $? -ne 0 ]; then
		version=$($runtime --version|tr '\n' ' ')
		die "failed to check config files - runtime is probably too old ($version)"
	fi

	subheading "Runtime default config files"

	show_quoted_text "" "$configs"

	# add in the standard defaults for good measure "just in case"
	configs+=( "/etc/kata-containers/configuration.toml" "/usr/share/defaults/kata-containers/configuration.toml" )

	# create a unique list of config files
	configs=$(echo $configs|tr ' ' '\n'|sort -u)

	subheading "Runtime config file contents"

	for config in $configs; do
		if [ -e "$config" ]; then
			run_cmd_and_show_quoted_output "toml" "cat \"$config\""
		else
			msg "Config file \`$config\` not found"
		fi
	done

	separator

	end_section
}

find_system_journal_problems()
{
	local name="$1"
	local program="$2"

	# select by identifier
	local selector="-t"

	local data_source="system journal"

	local problems=$(journalctl -q -o cat -a "$selector" "$program" |\
		grep "time=" |\
		egrep -i "$problem_pattern" |\
		egrep -iv "$problem_exclude_pattern" |\
		tail -n ${PROBLEM_LIMIT})

	if [ -n "$problems" ]; then
		msg "Recent $name problems found in $data_source:"
		show_quoted_text "" "$problems"
	else
		msg "No recent $name problems found in $data_source."
	fi
}

show_containerd_shimv2_log_details()
{
	local title="Kata Containerd Shim v2"
	subheading "$title logs"

	start_section "$title"
	find_system_journal_problems "$name" "kata"
	end_section
}

show_runtime_log_details()
{
	local title="Runtime logs"

	subheading "$title"

	start_section "$title"
	find_system_journal_problems "runtime" "kata-runtime"
	end_section
}

show_log_details()
{
	local title="Logfiles"
	start_section "$title"

	heading "$title"

	show_runtime_log_details
	show_containerd_shimv2_log_details

	separator

	end_section
}

show_package_versions()
{
	local title="Packages"

	start_section "$title"

	heading "$title"

	local pattern="("
	local project

	# CC 2.x, 3.0 and runv runtimes. They shouldn't be installed but let's
	# check anyway.
	pattern+="cc-oci-runtime"
	pattern+="|cc-runtime"
	pattern+="|runv"

	# core components
	for project in kata
	do
		pattern+="|${project}-runtime"
		pattern+="|${project}-containers-image"
	done

	# assets
	pattern+="|linux-container"

	# hypervisor name prefix
	pattern+="|qemu-"

	pattern+=")"

	if have_cmd "dpkg"; then
		run_cmd_and_show_quoted_output "" "dpkg -l|egrep \"$pattern\""
	fi

	if have_cmd "rpm"; then
		run_cmd_and_show_quoted_output "" "rpm -qa|egrep \"$pattern\""
	fi

	separator

	end_section
}

show_container_mgr_details()
{
	local title="Container manager details"
	start_section "$title"

	heading "$title"

	if have_cmd "docker" >/dev/null; then
		start_section "Docker"

		subheading "Docker"

		local -a cmds

		cmds+=("docker version")
		cmds+=("docker info")
		cmds+=("systemctl show docker")

		local cmd

		for cmd in "${cmds[@]}"
		do
			run_cmd_and_show_quoted_output "" "$cmd"
		done

		end_section
	fi

	if have_cmd "kubectl" >/dev/null; then
		title="Kubernetes"

		start_section "$title"

		subheading "$title"
		run_cmd_and_show_quoted_output "" "kubectl version"
		run_cmd_and_show_quoted_output "" "kubectl config view"

		local cmd="systemctl show kubelet"
		run_cmd_and_show_quoted_output "" "$cmd"

		end_section
	fi

	if have_cmd "crio" >/dev/null; then
		title="crio"
		start_section "$title"

		subheading "$title"

		run_cmd_and_show_quoted_output "" "crio --version"

		local cmd="systemctl show crio"
		run_cmd_and_show_quoted_output "" "$cmd"

		cmd="crio config"
		run_cmd_and_show_quoted_output "" "$cmd"

		end_section
	fi

	if have_cmd "containerd" >/dev/null; then
		title="containerd"
		start_section "$title"

		subheading "$title"

		run_cmd_and_show_quoted_output "" "containerd --version"

		local cmd="systemctl show containerd"
		run_cmd_and_show_quoted_output "" "$cmd"

		local file="/etc/containerd/config.toml"

		cmd="cat $file"
		run_cmd_and_show_quoted_output "toml" "$cmd"

		end_section
	fi

	if have_cmd "podman" >/dev/null; then
		title="Podman"

		start_section "$title"

		subheading "$title"
		run_cmd_and_show_quoted_output "" "podman --version"

		run_cmd_and_show_quoted_output "" "podman system info"

		local cmd file

		for file in {/etc,/usr/share}/containers/*.{conf,json}; do
			if [ -e "$file" ]; then
				cmd="cat $file"
				run_cmd_and_show_quoted_output "" "$cmd"
			fi
		done

		end_section
	fi

	separator

	end_section
}

show_meta()
{
	local date

	heading "Meta details"

	date=$(date '+%Y-%m-%d.%H:%M:%S.%N%z')
	msg "Running \`$script_name\` version \`$script_version\` at \`$date\`."
	show_latest_kata_version
	separator
}

show_runtime()
{
	local cmd

	start_section "Runtime"

	msg "Runtime is \`$runtime\`."

	cmd="kata-env"

	heading "\`$cmd\`"

	run_cmd_and_show_quoted_output "toml" "$runtime $cmd"

	separator

	end_section
}

show_containerd_shimv2()
{
	start_section "Containerd shim v2"

	local cmd="${containerd_shim_v2_name} --version"

	msg "Containerd shim v2 is \`$containerd_shim_v2\`."

	run_cmd_and_show_quoted_output "" "$cmd"

	separator

	end_section
}

# Parameter 1: Path to disk image file.
# Returns: Details of the image, or "$unknown" on error.
get_image_details()
{
	local img="$1"

	[ -z "$img" ] && { echo "$unknown"; return;}
	[ -e "$img" ] || { echo "$unknown"; return;}

	local loop_device
	local partition_path
	local partitions
	local partition
	local count
	local mountpoint
	local contents
	local expected

	loop_device=$(loopmount_image "$img")
	if [ -z "$loop_device" ]; then
		echo "$unknown"
		return
	fi

	partitions=$(get_partitions "$loop_device")
	count=$(echo "$partitions"|wc -l)

	expected=1

	if [ "$count" -ne "$expected" ]; then
		release_device "$loop_device"
		echo "$unknown"
		return
	fi

	partition="$partitions"

	partition_path="/dev/${partition}"
	if [ ! -e "$partition_path" ]; then
		release_device "$loop_device"
		echo "$unknown"
		return
	fi

	mountpoint=$(mount_partition "$partition_path")

	contents=$(read_osbuilder_file "${mountpoint}")
	[ -z "$contents" ] && contents="$unknown"

	unmount_partition "$mountpoint"
	release_device "$loop_device"

	echo "$contents"
}

# Parameter 1: Path to the initrd file.
# Returns: Details of the initrd, or "$unknown" on error.
get_initrd_details()
{
	local initrd="$1"

	[ -z "$initrd" ] && { echo "$unknown"; return;}
	[ -e "$initrd" ] || { echo "$unknown"; return;}

	local file
	local relative_file=""
	local tmp

	file="${osbuilder_file}"

	# All files in the cpio archive are relative so remove leading slash
	relative_file=$(echo "$file"|sed 's!^/!!g')

	local tmpdir=$(mktemp -d)

	# Note: 'cpio --directory' seems to be non-portable, so cd(1) instead.
	(cd "$tmpdir" && gzip -dc "$initrd" | cpio \
		--extract \
		--make-directories \
		--no-absolute-filenames \
		$relative_file 2>/dev/null)

	contents=$(read_osbuilder_file "${tmpdir}")
	[ -z "$contents" ] && contents="$unknown"

	tmp="${tmpdir}/${file}"
	[ -d "$tmp" ] && rm -rf "$tmp"

	echo "$contents"
}

# Returns: Full path to the image file.
get_image_file()
{
	local cmd="kata-env"
	local cmdline="$runtime $cmd"

	local image=$(eval "$cmdline" 2>/dev/null |\
		grep -A 1 '^\[Image\]' |\
		egrep "\<Path\> =" |\
		awk '{print $3}' |\
		tr -d '"')

	echo "$image"
}

# Returns: Full path to the initrd file.
get_initrd_file()
{
	local cmd="kata-env"
	local cmdline="$runtime $cmd"

	local initrd=$(eval "$cmdline" 2>/dev/null |\
		grep -A 1 '^\[Initrd\]' |\
		egrep "\<Path\> =" |\
		awk '{print $3}' |\
		tr -d '"')

	echo "$initrd"
}

# Parameter 1: Path to disk image file.
# Returns: Path to loop device.
loopmount_image()
{
	local img="$1"
	[ -n "$img" ] || die "need image file"

	local device_path

	losetup -fP "$img"

	device_path=$(losetup -j "$img" |\
		cut -d: -f1 |\
		sort -k1,1 |\
		tail -1)

	echo "$device_path"
}

# Parameter 1: Path to loop device.
# Returns: Partition names.
get_partitions()
{
	local device_path="$1"
	[ -n "$device_path" ] || die "need device path"

	local device
	local partitions

	device=${device_path/\/dev\//}

	partitions=$(lsblk -nli -o NAME "${device_path}" |\
		grep -v "^${device}$")

	echo "$partitions"
}

# Parameter 1: Path to disk partition device.
# Returns: Mountpoint.
mount_partition()
{
	local partition="$1"
	[ -n "$partition" ] || die "need partition"
	[ -e "$partition" ] || die "partition does not exist: $partition"

	local mountpoint

	mountpoint=$(mktemp -d)

	mount -oro,noload "$partition" "$mountpoint"

	echo "$mountpoint"
}

# Parameter 1: Mountpoint.
unmount_partition()
{
	local mountpoint="$1"
	[ -n "$mountpoint" ] || die "need mountpoint"
	[ -e "$mountpoint" ] || die "mountpoint does not exist: $mountpoint"

	umount "$mountpoint"
}

# Parameter 1: Loop device path.
release_device()
{
	local device="$1"
	[ -n "$device" ] || die "need device"
	[ -e "$device" ] || die "device does not exist: $device"

	losetup -d "$device"
}

show_kata_monitor_version()
{
	start_section "Kata Monitor"

	local cmd="${kata_monitor_name} --version"

	msg "Kata Monitor \`$kata_monitor_name\`."

	run_cmd_and_show_quoted_output "" "$cmd"

	separator

	end_section
}

# Retrieve details of the image containing
# the rootfs used to boot the virtual machine.
image_details()
{
	local image
	local details

	image=$(get_image_file)

	if [ -n "$image" ]
	then
		details=$(get_image_details "$image")
		msg "$details"
	else
		msg "No image"
	fi

}

show_image_details()
{
	local details

	local title="Image details"
	start_section "$title"

	heading "$title"

	details=$(image_details)
	if [ "$details" != "No image" ]; then
		show_quoted_text "yaml" "$details"
	else
		msg "$details"
	fi
	
	separator

	end_section
}

# Retrieve details of the initrd containing
# the rootfs used to boot the virtual machine.
initrd_details()
{
	
	local initrd
	local details

	initrd=$(get_initrd_file)

	if [ -n "$initrd" ]
	then
		details=$(get_initrd_details "$initrd")
		msg "$details"
	else
		msg "No initrd"
	fi

}

show_initrd_details()
{
	local details

	start_section "Initrd details"
	heading "Initrd details"

	details=$(initrd_details)

	if [ "$details" != "No initrd" ]; then
		show_quoted_text "yaml" "$details"
	else
		msg "$details"
	fi
	
	separator

	end_section
}

read_osbuilder_file()
{
	local rootdir="$1"

	[ -n "$rootdir" ] || die "need root directory"

	local file="${rootdir}/${osbuilder_file}"

	[ ! -e "$file" ] && return

	cat "$file"
}

show_latest_kata_version()
{
	if [ -z "$KATA_CHECK_NO_NETWORK" ]; then
		local rc=0
		local latest_version=$(sudo -u nobody kata-runtime kata-check --check-version-only 2>/dev/null || rc=$?)
		if [ "$rc" -ne 0 ]; then
			msg "Unable to check for latest version. Check if network is connected"
		else
			msg "$latest_version"
		fi
	else
		msg "KATA_CHECK_NO_NETWORK is set. Latest release cannot not be checked"
	fi
}

show_third_party_tools()
{
	not_found="Tool not found"
	start_section "Third Party Tools"

	conmon_version="$(conmon --version | awk -v FS="(^conmon version)|\n" '{print $2}' | xargs || true)"
	[ -z $conmon_version ] && conmon_version=$not_found
	msg "conmon version: $conmon_version"

	crio_version="$(crio --version | awk -v FS="(^Version:)|\n" '{print $2}' | xargs || true)"
	[ -z $crio_version ] && crio_version=$not_found
	msg "cri-o version: $crio_version"

	# Not in vagrant
	containerd_version="$(containerd --version | awk -F ' ' 'NR==1{print $3}' | xargs || true)"
	[ -z $containerd_version ] && $containerd_version=$not_found
	msg "containerd version: $containerd_version"

	critools_version="$(crictl --version | awk -v FS="(^crictl version)|\n" '{print $2}' | xargs || true)"
	[ -z $critools_version ] && critools_version=$not_found
	msg "critools version: $critools_version"

	# Not in vagrant
	gperf_version="$(gperf --version | awk -v FS="(GNU gperf)|\n" '{print $2}' | xargs || true)"
	[ -z $gperf_version ] && gperf_version=$not_found
	msg "gperf version: $gperf_version"

	kubernetes_version="$(kubectl version --output=json 2>/dev/null | jq -r '.clientVersion.gitVersion' || true)"
	[ -z $kubernetes_version ] && kubernetes_version=$not_found
	msg "kubernetes version: $kubernetes_version"

	libseccomp_version="$(runc --version | awk -v FS="(^libseccomp:)|\n" '{print $2}' | xargs || true)"
	[ -z $libseccomp_version ] && libseccomp_version=$not_found
	msg "libseccomp version: $libseccomp_version"

	runc_version="$(runc --version | awk -v FS="(^runc version)|\n" '{print $2}' | xargs)"
	[ -z $runc_version ] && runc_version=$not_found
	msg "runc version: $runc_version"

	end_section

}

show_details()
{
	show_header

	show_meta
	show_runtime
	show_runtime_configs
	show_containerd_shimv2
	show_image_details
	show_initrd_details
	show_log_details
	show_container_mgr_details
	show_package_versions
	show_kata_monitor_version
	show_third_party_tools

	show_footer
}

main()
{
	if [ "$1" = "show-image-details" ]; then
		image_details && initrd_details && exit 0 || die "failed to determine image details"
	fi

	args=$(getopt \
		-n "$script_name" \
		-a \
		--options="dhv" \
		--longoptions="debug help version" \
		-- "$@")

	eval set -- "$args"
	[ $? -ne 0 ] && { usage && exit 1; }
	[ $# -eq 0 ] && { usage && exit 0; }

	while [ $# -gt 1 ]
	do
		case "$1" in
			-d|--debug)
				set -x
				;;

			-h|--help)
				usage && exit 0
				;;

			-v|--version)
				version && exit 0
				;;

			--)
				shift
				break
				;;
		esac
		shift
	done

	[ $(id -u) -eq 0 ] || die "Need to run as root"
	[ -n "$runtime" ] || die "cannot find runtime '$runtime_name'"

	show_details
}

main "$@"
