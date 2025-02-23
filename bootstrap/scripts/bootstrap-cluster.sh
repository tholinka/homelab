#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Apply the Talos configuration to all the nodes
function apply_talos_config() {
	log debug "Applying Talos configuration"

	task talos:generate-config

	cp talos/clusterconfig/talosconfig "$HOME/.talos/config"

	# Apply the Talos configuration to the nodes
	if ! nodes=$(talosctl config info --output json 2>/dev/null | jq --exit-status --raw-output '.nodes | join(" ")') || [[ -z "${nodes}" ]]; then
		log error "No Talos nodes found"
	fi

	log debug "Talos nodes discovered" "nodes=${nodes}"

	pushd "${ROOT_DIR}/talos" >/dev/null

	# Apply the Talos configuration
	for node in ${nodes}; do
		log debug "Applying Talos node configuration" "node=${node}"

		if ! output=$(talhelper gencommand apply --node "${node}" --extra-flags="--insecure" | bash 2>&1);
		then
			if [[ "${output}" == *"certificate required"* ]]; then
				log warn "Talos node is already configured, skipping apply of config" "node=${node}"
				continue
			fi
			log error "Failed to apply Talos node configuration" "node=${node}" "output=${output}"
		fi

		log info "Talos node configuration applied successfully" "node=${node}"
	done

	popd
}

# Bootstrap Talos on a controller node
function bootstrap_talos() {
	log debug "Bootstrapping Talos"

	pushd "${ROOT_DIR}/talos" >/dev/null

	local bootstrapped=true

	if ! controller=$(talosctl config info --output json | jq --exit-status --raw-output '.endpoints[]' | shuf -n 1) || [[ -z "${controller}" ]]; then
		log error "No Talos controller found"
	fi

	log debug "Talos controller discovered" "controller=${controller}"

	until output=$(talhelper gencommand bootstrap --node "${controller}" | bash 2>&1); do
		if [[ "${bootstrapped}" == true ]]; then
			if [[ "${output}" == *"AlreadyExists"* ]]; then
			log info "Talos is bootstrapped" "controller=${controller}"
			break
			elif [[ "${output}" == *"expired certificate"* ]]; then
				log info "Talos is updating (got expired certificate), retrying in 1 second..." "controller=${controller}"
				sleep 1;
				continue;
			fi
		fi

		# Set bootstrapped to false after the first attempt
		bootstrapped=false

		log info "Talos bootstrap failed, retrying in 10 seconds..." "controller=${controller}"
		sleep 10
	done

	popd >/dev/null
}

# Fetch the kubeconfig from a controller node
function fetch_kubeconfig() {
	log debug "Fetching kubeconfig"

	pushd "${ROOT_DIR}/talos" >/dev/null

	if ! controller=$(talosctl config info --output json | jq --exit-status --raw-output '.endpoints[]' | shuf -n 1) || [[ -z "${controller}" ]]; then
		log error "No Talos controller found"
	fi

	if ! talosctl kubeconfig --nodes "${controller}" --force --force-context-name main "$(basename "${ROOT_DIR}/kubeconfig")" &>/dev/null; then
		log error "Failed to fetch kubeconfig"
	fi

	cp "${ROOT_DIR}/kubeconfig" "$HOME/.kube/config"

	log info "Kubeconfig fetched successfully"

	popd >/dev/null
}

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
function add_nas_to_cluster() ( #subshell
	source "$(dirname "${0}")/lib/common.sh"

	function do_ssh() {
		ssh -t nas.servers.internal "$@"
	}

	if ! controller=$(talosctl config info --output json | jq --exit-status --raw-output '.endpoints[]' | shuf -n 1) || [[ -z "${controller}" ]]; then
		log error "No Talos controller found"
	fi

	local CLUSTER_DOMAIN
	CLUSTER_DOMAIN="$(talosctl -n "$controller" get kubeletconfig -o jsonpath="{.spec.clusterDomain}")"
	local CLUSTER_DNS
	CLUSTER_DNS="$(talosctl -n "$controller" get kubeletconfig -o jsonpath="{.spec.clusterDNS}")"
	local SOCKET_PATH
	SOCKET_PATH=/var/run/containerd/containerd.sock
	local TMPDIR
	TMPDIR=$(mktemp -d)

	function do_talos() {
		talosctl -n "$controller" "$@"
	}

	# wait for nas to be up
	until do_ssh -o ConnectTimeout=1 'exit 0';
		log info "NAS not online, sleeping for 5 seconds..."
		do sleep 5;
	done

	## remove existing

	set -x
	# this can fail
	# shellcheck disable=SC2015
	do_ssh 'systemctl is-active kubelet.service containerd.service 1>/dev/null && \
	sudo systemctl disable kubelet.service containerd.service && \
	sudo reboot' && sleep 10 || true

	set +x
	until do_ssh -o ConnectTimeout=1 'exit 0';
		log info "NAS not online, sleeping for 5 seconds..."
		do sleep 5;
	done
	set -x;

	do_ssh 'sudo find /var/lib/containerd/io.containerd.snapshotter.v1.btrfs/snapshots/ -maxdepth 1 -type d -exec btrfs subvolume delete {} \; ; \
		sudo rm -rf \
		/var/lib/containerd /var/lib/kubelet /var/lib/cni /var/local/openebs \
		/etc/kubernetes /etc/cni \
		/opt/cni'

	## copy files from talos cluster
	do_talos cat /etc/kubernetes/kubeconfig-kubelet > "$TMPDIR/kubelet.conf"
	do_talos cat /etc/kubernetes/bootstrap-kubeconfig > "$TMPDIR/bootstrap-kubelet.conf"
	do_talos cat /etc/kubernetes/pki/ca.crt > $TMPDIR/ca.crt
	sed -i "/server:/ s|:.*|: https://192.168.20.2:6443|g" "$TMPDIR/kubelet.conf" "$TMPDIR/bootstrap-kubelet.conf"
	cat > "$TMPDIR/var-lib-kubelet-config.yaml" <<- _EOT
		kind: KubeletConfiguration
		apiVersion: kubelet.config.k8s.io/v1beta1
		authentication:
			anonymous:
			enabled: false
			webhook:
			enabled: true
			x509:
			clientCAFile: /etc/kubernetes/pki/ca.crt
		authorization:
			mode: Webhook
		clusterDomain: "$CLUSTER_DOMAIN"
		clusterDNS: $CLUSTER_DNS
		runtimeRequestTimeout: "0s"
		cgroupDriver: systemd
		containerRuntimeEndpoint: unix:/$SOCKET_PATH
	_EOT
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
)

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
	log debug "Waiting for nodes to be available"

	# Skip waiting if all nodes are 'Ready=True'
	if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
		log info "Nodes are available and ready, skipping wait for nodes"
		return
	fi

	# Wait for all nodes to be 'Ready=False'
	until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
		log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
		sleep 10
	done
}

# Resources to be applied before the helmfile charts are installed
function apply_resources() {
	log debug "Applying resources"

	local -r resources_file="${ROOT_DIR}/bootstrap/resources.yaml.j2"

	if ! output=$(render_template "${resources_file}") || [[ -z "${output}" ]]; then
		exit 1
	fi

	if echo "${output}" | kubectl diff --filename - &>/dev/null; then
		log info "Resources are up-to-date"
		return
	fi

	if response=$(echo "${output}" | kubectl apply --server-side --filename - &>/dev/null); then
		log info "Resources applied"
	else
		log error "Failed to apply resources" "response=${response}"
	fi
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

	if ! nodes=$(talosctl config info --output json 2>/dev/null | jq --exit-status --raw-output '.nodes | join(" ")') || [[ -z "${nodes}" ]]; then
		log error "No Talos nodes found"
	fi

	log debug "Talos nodes discovered" "nodes=${nodes}"

	# Wipe disks on each node that match the ROOK_DISK environment variable
	for node in ${nodes}; do
		# see kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml -> spec.values.cephClusterSpec.storage.devicePathFilter, that regex needs to match these models!
		if ! disks=$(talosctl --nodes "${node}" get disk --output json 2>/dev/null \
			| jq --exit-status --raw-output --slurp '. | map(select(.spec.model == env.ROOK_DISK_0 or .spec.model == env.ROOK_DISK_1) | .metadata.id) | join(" ")') || [[ -z "${nodes}" ]];
		then
			log error "No disks found" "node=${node}" "model=${ROOK_DISK_0} or ${ROOK_DISK_1}"
		fi

		if [[ -z $disks ]]; then
			log debug "Talos node has no disk matching models" "node=${node}" "model=${ROOK_DISK_0} or ${ROOK_DISK_1}"
		fi

		log debug "Talos node and disk discovered" "node=${node}" "disks=${disks}"

		# Wipe each disk on the node
		for disk in ${disks}; do
			if talosctl --nodes "${node}" wipe disk "${disk}" &>/dev/null; then
				log info "Disk wiped" "node=${node}" "disk=${disk}"
			else
				log error "Failed to wipe disk" "node=${node}" "disk=${disk}"
			fi
		done
	done
}

# Apply Helm releases using helmfile
function apply_helm_releases() {
	log debug "Applying Helm releases with helmfile"

	local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.yaml"

	if [[ ! -f "${helmfile_file}" ]]; then
		log error "File does not exist" "file=${helmfile_file}"
	fi

	if ! helmfile --file "${helmfile_file}" apply --skip-diff-on-install --suppress-diff --suppress-secrets; then
		log error "Failed to apply Helm releases"
	fi

	log info "Helm releases applied successfully"
}

function main() {
	check_env KUBECONFIG ROOK_DISK_0 ROOK_DISK_1
	check_cli helmfile jq kubectl kustomize minijinja-cli bws talosctl yq

	if ! bws project list &>/dev/null; then
		log error "Failed to authenticate with Bitwarden Seccret Manager CLI"
	fi

	# Bootstrap the Talos node configuration
	apply_talos_config
	bootstrap_talos
	fetch_kubeconfig
	if [[ $ADD_NAS == 'true' ]]; then
		add_nas_to_cluster
	fi

	# Apply resources and Helm releases
	wait_for_nodes
	wipe_rook_disks
	apply_resources
	apply_helm_releases

	log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
}

main "$@"
