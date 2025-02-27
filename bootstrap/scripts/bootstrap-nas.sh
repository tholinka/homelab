#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

function do_ssh() {
	ssh -t nas.servers.internal "$@"
}

if ! controller=$(talosctl config info --output json | jq --exit-status --raw-output '.endpoints[]' | shuf -n 1) || [[ -z "${controller}" ]]; then
	log error "No Talos controller found"
fi

function do_talos() {
	talosctl -n "$controller" "$@"
}

function sleep_until_on() {
	until do_ssh -o ConnectTimeout=1 'exit 0'; do
		log info "NAS not online, sleeping for 5 seconds..."
		sleep 5;
	done
}

function remove_existing() {
	set -x;
	# this can fail
	# shellcheck disable=SC2015
	do_ssh 'systemctl is-active kubelet.service containerd.service 1>/dev/null && \
	sudo systemctl disable kubelet.service containerd.service && \
	sudo reboot' && sleep 10 || true

	set +x
	sleep_until_on
	set -x;

	do_ssh 'sudo find /var/lib/containerd/io.containerd.snapshotter.v1.btrfs/snapshots/ -maxdepth 1 -type d -exec btrfs subvolume delete {} \; ; \
		sudo rm -rf \
		/var/lib/containerd /var/lib/kubelet /var/lib/cni /var/local/openebs \
		/etc/kubernetes /etc/cni \
		/opt/cni'
}

# Disks in use by rook-ceph must be wiped before Rook is installed
function wipe_rook_disks() {
	log debug "Wiping Rook disks"

	# Skip disk wipe if Rook is detected running in the cluster
	# TODO: Is there a better way to detect Rook / OSDs?
	if kubectl --namespace rook-ceph get kustomization rook-ceph &>/dev/null; then
		log warn "Rook is detected running in the cluster, skipping disk wipe"
		return
	fi

	# this needs to match the regex in rook-ceph cluster's helmrelease
	do_ssh 'find /dev/disk/by-id/ -regextype posix-extended -regex "^/dev/disk/by-id/(nvme-SPCC_M.2_PCIe_SSD).*" -not -name "*_[0-9]" -not -name "*-part[0-9]" | xargs -I% sh -c "nvme format --lbaf=1 % --force && nvme format --block-size=4096 % --force"'

	log "Wiped Ceph drive"
}

function do_template_var_lib_kubelet_config() ( # subshell so we don't pollute with the exports
	CLUSTER_DOMAIN="$(talosctl -n "$controller" get kubeletconfig -o jsonpath="{.spec.clusterDomain}")"
	export CLUSTER_DOMAIN
	CLUSTER_DNS="$(talosctl -n "$controller" get kubeletconfig -o jsonpath="{.spec.clusterDNS}")"
	export CLUSTER_DNS
	export SOCKET_PATH=/var/run/containerd/containerd.sock

	minijinja-cli --env "$ROOT_DIR/bootstrap/nas-var-lib-kubelet-config.yaml.j2"
)

# Add NAS to cluster
# - See https://github.com/siderolabs/talos/issues/3990 for more info.
# - ensure you do the configuration that's in talos/patches/global manually!
# 	especially the machine-network and machine-files ones!
# - ensure HAProxy is setup to mimic KubePrism, or Cilium will fail:
# 	defaults
# 		timeout client 10s
# 		timeout connect 5s
# 		timeout server 10s

# 	frontend kubeprism
# 		mode tcp
# 		bind 127.0.0.1:7445
# 		default_backend k8s_api

# 	backend k8s_api
# 		mode tcp
# 		server lb 192.168.20.2:6443 check
# 		server c1 192.168.20.61:6443 check backup
# 		server c2 192.168.20.62:6443 check backup
# 	server c3 192.168.20.63:6443 check backup
function add_nas_to_cluster() {
	source "$(dirname "${0}")/lib/common.sh"

	local TMPDIR
	TMPDIR=$(mktemp -d)

	set -x

	## copy files from talos cluster
	do_talos cat /etc/kubernetes/kubeconfig-kubelet > "$TMPDIR/kubelet.conf"
	do_talos cat /etc/kubernetes/bootstrap-kubeconfig > "$TMPDIR/bootstrap-kubelet.conf"
	do_talos cat /etc/kubernetes/pki/ca.crt > $TMPDIR/ca.crt
	sed -i "/server:/ s|:.*|: https://192.168.20.2:6443|g" "$TMPDIR/kubelet.conf" "$TMPDIR/bootstrap-kubelet.conf"
	do_template_var_lib_kubelet_config > "$TMPDIR/var-lib-kubelet-config.yaml"
	cat > "$TMPDIR/kubelet.env" <<- _EOT
		KUBELET_ARGS="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf --config=/var/lib/kubelet/config.yaml --fail-swap-on=false"
	_EOT

	scp -r "$TMPDIR" "nas.servers.internal:$TMPDIR"

	do_ssh "sudo mkdir -p /etc/kubernetes/pki /var/lib/kubelet &&
		sudo mv $TMPDIR/kubelet.conf /etc/kubernetes/kubelet.conf &&
		sudo mv $TMPDIR/bootstrap-kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf &&
		sudo mv $TMPDIR/ca.crt /etc/kubernetes/pki/ca.crt &&
		sudo mv $TMPDIR/var-lib-kubelet-config.yaml /var/lib/kubelet/config.yaml &&
		sudo mv $TMPDIR/kubelet.env /etc/kubernetes/kubelet.env &&
		sudo systemctl enable --now containerd.service kubelet.service"

	set +x
}

function main() {
	check_env KUBECONFIG
	check_cli ssh kubectl minijinja-cli talosctl

	sleep_until_on

	remove_existing

	wipe_rook_disks

	add_nas_to_cluster

	log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
}

main "$@"
