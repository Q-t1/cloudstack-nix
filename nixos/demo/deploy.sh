# Deploys the demo's zone on the simulator hypervisor, like
# tests/simulator.nix (after upstream's Marvin configuration
# setup/dev/advanced.cfg), then a network and a VM in it. Does nothing when the
# zone exists. CloudMonkey's defaults (admin/password on localhost:8080) match
# the server's; async APIs block until their job ends.

zone_name=Demo

api() {
  cloudstack-cloudmonkey -o json "$@"
}

# Waits until a jq filter holds for the output of an API call.
wait_for() {
  local filter=$1
  shift
  until api "$@" | jq -e "$filter" > /dev/null; do
    sleep 5
  done
}

# Unauthenticated calls get a 401 once the API is up.
echo "Waiting for the API"
until [ "$(curl -s -o /dev/null -w '%{http_code}' 'http://localhost:8080/client/api?command=listCapabilities')" = 401 ]; do
  sleep 5
done
api sync > /dev/null

state=$(api list zones name="$zone_name" | jq -r '.zone[0].allocationstate // empty')
if [ "$state" = Enabled ]; then
  echo "The zone $zone_name exists already"
  exit 0
elif [ -n "$state" ]; then
  echo "The zone $zone_name exists but is not enabled: a previous deployment failed." \
    "Delete it, then restart cloudstack-demo.service." >&2
  exit 1
fi

echo "Deploying the zone $zone_name on simulated hosts"
zone=$(api create zone \
  name="$zone_name" networktype=Advanced guestcidraddress=10.1.1.0/24 \
  dns1=10.147.28.6 internaldns1=10.147.28.6 |
  jq -er .zone.id)

pnet=$(api create physicalnetwork \
  zoneid="$zone" name=Demo-pnet isolationmethods=VLAN broadcastdomainrange=Zone vlan=100-200 |
  jq -er .physicalnetwork.id)
for traffic in Guest Management Public; do
  api add traffictype physicalnetworkid="$pnet" traffictype="$traffic" > /dev/null
done
api update physicalnetwork id="$pnet" state=Enabled > /dev/null

provider=$(api list networkserviceproviders name=VirtualRouter physicalnetworkid="$pnet" |
  jq -er '.networkserviceprovider[0].id')
element=$(api list virtualrouterelements nspid="$provider" | jq -er '.virtualrouterelement[0].id')
api configure virtualrouterelement id="$element" enabled=true > /dev/null
api update networkserviceprovider id="$provider" state=Enabled > /dev/null

api create vlaniprange \
  zoneid="$zone" vlan=50 forvirtualnetwork=true \
  gateway=192.168.2.1 netmask=255.255.255.0 startip=192.168.2.2 endip=192.168.2.200 > /dev/null
pod=$(api create pod \
  zoneid="$zone" name=POD0 \
  gateway=172.16.15.1 netmask=255.255.255.0 startip=172.16.15.2 endip=172.16.15.200 |
  jq -er .pod.id)
cluster=$(api add cluster \
  zoneid="$zone" podid="$pod" clustername=C0 hypervisor=Simulator clustertype=CloudManaged |
  jq -er '.cluster[0].id')
for host in h0 h1; do
  api add host \
    zoneid="$zone" podid="$pod" clusterid="$cluster" hypervisor=Simulator \
    url="http://sim/c0/$host" username=root password=password > /dev/null
done
api create storagepool \
  zoneid="$zone" podid="$pod" clusterid="$cluster" \
  name=PS0 url=nfs://10.147.28.6/export/home/sandbox/primary0 > /dev/null
api add imagestore \
  zoneid="$zone" provider=NFS \
  name=SS0 url=nfs://10.147.28.6/export/home/sandbox/secondary > /dev/null
api update zone id="$zone" allocationstate=Enabled > /dev/null

echo "Waiting for the hosts and the system VMs"
wait_for '.count == 2 and all(.host[]; .state == "Up")' list hosts type=Routing zoneid="$zone"
wait_for '.count == 2 and all(.systemvm[]; .state == "Running")' list systemvms zoneid="$zone"

echo "Deploying a VM in an isolated network"
# The simulator's featured template, once the secondary storage VM has it.
until template=$(api list templates templatefilter=featured zoneid="$zone" |
  jq -er '[.template[]? | select(.hypervisor == "Simulator" and .isready)][0].id'); do
  sleep 5
done
network_offering=$(api list networkofferings name=DefaultIsolatedNetworkOfferingWithSourceNatService |
  jq -er '.networkoffering[0].id')
network=$(api create network \
  zoneid="$zone" name=demo-network displaytext="Demo network" networkofferingid="$network_offering" |
  jq -er .network.id)
service_offering=$(api list serviceofferings name="Small Instance" | jq -er '.serviceoffering[0].id')
api deploy virtualmachine \
  zoneid="$zone" templateid="$template" serviceofferingid="$service_offering" \
  networkids="$network" name=demo-vm > /dev/null

echo "The zone $zone_name is ready, with the VM demo-vm"
