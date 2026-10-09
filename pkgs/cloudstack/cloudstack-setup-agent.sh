#!@shell@
# Stands in for upstream's cloudstack-setup-agent, which the management server
# runs over SSH when a KVM host is added:
#
#   cloudstack-setup-agent -m <management servers> -z <zone> -p <pod> \
#     -c <cluster> -g <guid> -a -s --pubNic=<device> --prvNic=<device> \
#     --guestNic=<device> --hypervisor=kvm
#
# Upstream's script also rewrites the network, libvirt, firewall and
# AppArmor/SELinux configuration of the host. On NixOS those come from the
# system configuration, so this one only records where the host belongs in
# agent.properties, like upstream's last step, then restarts the agent.
#
# Environment:
#   CLOUDSTACK_CONF_DIR  directory holding agent.properties, as for
#                        cloudstack-agent. Default: /etc/cloudstack/agent
set -euo pipefail

export PATH="@path@:$PATH:/run/current-system/sw/bin"

conf_dir="${CLOUDSTACK_CONF_DIR:-/etc/cloudstack/agent}"
props="$conf_dir/agent.properties"

usage() {
  echo "usage: $0 -a -m HOSTS -z ZONE -p POD -c CLUSTER -g GUID" \
    "--pubNic=DEV --prvNic=DEV --guestNic=DEV [--hypervisor=kvm] [-s]" >&2
  exit 1
}

auto=0
secure=0
hypervisor=kvm
mgt="" zone="" pod="" cluster="" guid="" pub_nic="" prv_nic="" guest_nic=""
while [ $# -gt 0 ]; do
  option=$1
  shift
  value=""
  case $option in
    -a) auto=1; continue ;;
    -s) secure=1; continue ;;
    --*=*) value=${option#*=}; option=${option%%=*} ;;
    -m | -z | -p | -c | -g | -t | --host | --zone | --pod | --cluster | --guid | --hypervisor | \
      --pubNic | --prvNic | --guestNic)
      [ $# -gt 0 ] || usage
      value=$1
      shift
      ;;
    *) usage ;;
  esac
  case $option in
    -m | --host) mgt=$value ;;
    -z | --zone) zone=$value ;;
    -p | --pod) pod=$value ;;
    -c | --cluster) cluster=$value ;;
    -g | --guid) guid=$value ;;
    -t | --hypervisor) hypervisor=$value ;;
    --pubNic) pub_nic=$value ;;
    --prvNic) prv_nic=$value ;;
    --guestNic) guest_nic=$value ;;
    *) usage ;;
  esac
done

if [ "$auto" -eq 0 ]; then
  if [ "$secure" -eq 1 ]; then
    # Upstream configures libvirtd for TLS here.
    echo "libvirtd is configured by NixOS, nothing to do."
    exit 0
  fi
  echo "Only the non-interactive mode (-a), used by the management server, is supported." >&2
  usage
fi
for required in mgt zone pod cluster guid pub_nic prv_nic guest_nic; do
  if [ -z "${!required}" ]; then
    echo "Missing operand: $required" >&2
    usage
  fi
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Must run as root." >&2
  exit 1
fi

# The property's value, or nothing.
get_property() {
  [ -f "$props" ] || return 0
  key=$1 awk '
    { line = $0; sub(/^[ \t]+/, "", line) }
    substr(line, 1, length(ENVIRON["key"])) == ENVIRON["key"] &&
      substr(line, length(ENVIRON["key"]) + 1) ~ /^[ \t]*[=:]/ {
      sub(/^[^=:]*[=:][ \t]*/, "", line); print line; exit
    }
  ' "$props"
}

# Replaces the first entry for the key (and drops any other), or appends one.
# The file is replaced atomically, like upstream's configFileOps does.
set_property() {
  local tmp
  tmp=$(mktemp "$conf_dir/.agent.properties.XXXXXX")
  touch "$props"
  key=$1 value=$2 awk '
    { line = $0; sub(/^[ \t]+/, "", line) }
    substr(line, 1, length(ENVIRON["key"])) == ENVIRON["key"] &&
      substr(line, length(ENVIRON["key"]) + 1) ~ /^[ \t]*[=:]/ {
      if (!done) print ENVIRON["key"] "=" ENVIRON["value"]
      done = 1
      next
    }
    { print }
    END { if (!done) print ENVIRON["key"] "=" ENVIRON["value"] }
  ' "$props" > "$tmp"
  chmod --reference="$props" "$tmp"
  mv "$tmp" "$props"
}

mkdir -p "$conf_dir"
set_property host "$mgt"
set_property zone "$zone"
set_property pod "$pod"
set_property cluster "$cluster"
set_property hypervisor.type "$hypervisor"
set_property port 8250
set_property private.network.device "$prv_nic"
set_property public.network.device "$pub_nic"
set_property guest.network.device "$guest_nic"
set_property guid "$guid"
if [ -z "$(get_property local.storage.uuid)" ]; then
  set_property local.storage.uuid "$(cat /proc/sys/kernel/random/uuid)"
fi
if [ -z "$(get_property resource)" ]; then
  set_property resource com.cloud.hypervisor.kvm.resource.LibvirtComputingResource
fi

systemctl restart cloudstack-agent.service
echo "CloudStack Agent setup is done!"
