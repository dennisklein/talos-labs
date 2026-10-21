# shellcheck shell=bash
# Sourced by the stage tasks. mise provides [env] (CLUSTER, SUBNET, TALOSCONFIG, KUBECONFIG,
# optional TALOS_VERSION, CILIUM_VERSION) and [tools]. TALOSCONFIG and KUBECONFIG are per stage,
# so talosctl and kubectl need no --context.
set -euo pipefail

# Image Factory schematic without customizations (no extensions, no extra kernel arguments)
EMPTY_SCHEMATIC=376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba
FACTORY=https://factory.talos.dev

build_dir() { dirname "$KUBECONFIG"; }
state_dir() { echo "$(build_dir)/state"; }

# vX.Y.Z: TALOS_VERSION if set, else the version of talosctl (mise installs the latest release)
talos_version() {
  local v="${TALOS_VERSION:-}"
  [ -n "$v" ] || v="$(talosctl version --client | awk '/Tag:/ {print $2; exit}')"
  echo "v${v#v}"
}

# Patch release before talos_version (v1.14.4 -> v1.14.3). For a .0 release, talos_version itself:
# then the upgrade stage changes only the schematic.
talos_previous_version() {
  local v patch
  v="$(talos_version)"
  patch="${v##*.}"
  if [ "$patch" -gt 0 ]; then echo "${v%.*}.$((patch - 1))"; else echo "$v"; fi
}

check_talos_version() {
  local v minor
  v="$(talos_version)"
  minor="$(echo "$v" | cut -d. -f2)"
  if [ "$(echo "$v" | cut -d. -f1)" = v1 ] && [ "$minor" -lt 14 ]; then
    echo "error: Talos $v; the labs need Talos 1.14 or later" >&2
    return 1
  fi
}

check_qemu() {
  [ -e /dev/kvm ] || { echo "error: /dev/kvm not found; the QEMU stages need KVM" >&2; return 1; }
  command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu-system-x86_64 not found" >&2; return 1; }
}

# Address of node <n> in SUBNET: 1 is the first control plane node (.2), then the next ones
node_ip() { echo "${SUBNET%.*}.$(($1 + 1))"; }

# --config-patch flags: patches/*.yaml for all nodes, patches/controlplane/*.yaml, patches/worker/*.yaml
patch_flags() {
  local f
  for f in patches/*.yaml; do [ -e "$f" ] && echo "--config-patch=@$f"; done
  for f in patches/controlplane/*.yaml; do [ -e "$f" ] && echo "--config-patch-controlplanes=@$f"; done
  for f in patches/worker/*.yaml; do [ -e "$f" ] && echo "--config-patch-workers=@$f"; done
  return 0
}

# A new cluster merges its context into TALOSCONFIG and KUBECONFIG. Start from empty files, so that
# the context names stay "<cluster>" and "admin@<cluster>".
fresh_configs() {
  mkdir -p "$(build_dir)"
  rm -f "$TALOSCONFIG" "$KUBECONFIG"
}

talos_up_docker() {  # extra flags (--workers, ...) are passed through
  local patches
  mapfile -t patches < <(patch_flags)
  fresh_configs
  talosctl cluster create docker --name "$CLUSTER" --subnet "$SUBNET" --state "$(state_dir)" \
    --talosconfig-destination "$TALOSCONFIG" --image "ghcr.io/siderolabs/talos:$(talos_version)" \
    "${patches[@]}" "$@"
  talosctl config node "$(node_ip 1)"
}

talos_down_docker() {
  [ -d "$(state_dir)/$CLUSTER" ] || { echo "no cluster $CLUSTER"; return 0; }
  talosctl cluster destroy --name "$CLUSTER" --state "$(state_dir)"
}

# QEMU needs root (bridge, CNI plugins, KVM). sudo resets PATH, so give the absolute path of
# talosctl. HOME stays: the CNI bundle and the boot image cache go to ~/.talos.
sudo_talosctl() {
  sudo --preserve-env=HOME,TALOSCONFIG,KUBECONFIG "$(command -v talosctl)" "$@"
}

# firewalld puts an unknown interface into the default zone, which rejects DHCP (UDP 67) from the
# VMs. Wait for the bridge of the cluster (the interface with the gateway address) and put it into
# the zone "trusted", for this boot only. Without firewalld, do nothing.
firewalld_trust_bridge() {
  systemctl is-active --quiet firewalld 2>/dev/null || return 0
  local gw="${SUBNET%.*}.1/" br="" i
  for i in $(seq 300); do
    br="$(ip -br addr | awk -v gw="$gw" 'index($3, gw) == 1 {print $1}')"
    [ -n "$br" ] && break
    sleep 1
  done
  [ -n "$br" ] || { echo "firewalld: no bridge with ${gw%/} after ${i}s" >&2; return 0; }
  sudo firewall-cmd --zone=trusted --add-interface="$br" >/dev/null && echo "firewalld: $br is in the zone trusted"
}

talos_up_qemu() {  # extra flags (--workers, --controlplanes, --disks, --presets, ...) are passed through
  local patches
  mapfile -t patches < <(patch_flags)
  fresh_configs
  firewalld_trust_bridge &
  sudo_talosctl cluster create qemu --name "$CLUSTER" --cidr "$SUBNET" --state "$(state_dir)" \
    --talosconfig-destination "$TALOSCONFIG" --talos-version "$(talos_version)" \
    "${patches[@]}" "$@"
  wait
  own_configs
  talosctl config node "$(node_ip 1)"
}

# talosctl ran as root: give the configuration files back to the user
own_configs() {
  local f
  for f in "$TALOSCONFIG" "$KUBECONFIG"; do
    [ -e "$f" ] && sudo chown "$(id -u):$(id -g)" "$f"
  done
  return 0
}

talos_down_qemu() {
  [ -d "$(state_dir)/$CLUSTER" ] || { echo "no cluster $CLUSTER"; return 0; }
  sudo_talosctl cluster destroy --name "$CLUSTER" --state "$(state_dir)"
}

# Installer image of the Image Factory for a schematic (default: no customizations)
installer_image() { echo "factory.talos.dev/metal-installer/${1:-$EMPTY_SCHEMATIC}:$(talos_version)"; }

# Upload a schematic file to the Image Factory and print its ID. The ID is a hash of the content:
# the same file gives the same ID.
schematic_id() {
  curl -fsS -X POST --data-binary @"$1" "$FACTORY/schematics" | jq -r .id
}

# Kubernetes version that talosctl installs by default, for example 1.37.1
k8s_default_version() {
  talosctl cluster create qemu --help | sed -n 's/.*--kubernetes-version.*(default "\(.*\)").*/\1/p'
}

# Latest patch release of the Kubernetes minor version before the default, for example 1.36.4
k8s_previous_version() {
  local minor
  minor="$(k8s_default_version | cut -d. -f2)"
  curl -fsSL "https://dl.k8s.io/release/stable-1.$((minor - 1)).txt" | sed 's/^v//'
}

wait_k8s_api() {  # <kubeconfig>: wait until the API server answers
  until kubectl --kubeconfig "$1" get --raw=/readyz >/dev/null 2>&1; do sleep 5; done
}

# CILIUM_VERSION if set, else the latest stable release, else (offline) the cilium-cli default.
cilium_version() {
  if [ -n "${CILIUM_VERSION:-}" ]; then echo "$CILIUM_VERSION"; return; fi
  cilium version --client 2>/dev/null | sed -n 's/^cilium image (stable): v\([0-9][0-9.]*\)$/\1/p' || true
}

cilium_up() {  # extra flags are passed through
  local version
  version="$(cilium_version)"
  cilium install ${version:+--version "$version"} --values values.yaml "$@"
}
