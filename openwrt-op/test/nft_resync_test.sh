#!/bin/bash
# Regression test: miniupnpd must keep managing its nftables rules after a
# rule dump was interrupted.
#
# A large upnp chain is dumped in several datagrams; changing any rule while
# that happens makes the kernel flag the dump NLM_F_DUMP_INTR. Stock 2.3.9
# then leaves the rest of the reply on its netlink socket and every later
# request fails: mappings can no longer be removed (seen on a router as
# 11k expired NAT-PMP mappings and a "refresh_nft_cache: mnl_cb_run returned
# -1" flood). After the churn stops, every mapping must still be deletable.
#
#   sudo ./nft_resync_test.sh /path/to/miniupnpd
# Exit 0 = PASS, 1 = FAIL (rules left behind or errors after the churn),
# 2 = the churn never interrupted a dump, so nothing was tested.
set -u
BIN=$(readlink -f "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
N=${N:-1200}           # mappings that make the chain span many datagrams
CHURN_SECS=${CHURN_SECS:-20}
W=$(mktemp -d)
LOG=$W/miniupnpd.log
NS=mupc

cleanup() {
	[ -n "${CHURN:-}" ] && kill "$CHURN" 2> /dev/null
	[ -n "${MUPD:-}" ] && kill "$MUPD" 2> /dev/null
	wait 2> /dev/null
	ip netns del $NS 2> /dev/null
	ip link del veth-gw 2> /dev/null
	ip link del mupx0 2> /dev/null
	nft delete table inet mtest 2> /dev/null
	rm -rf "$W"
}
trap cleanup EXIT

client() { ip netns exec $NS python3 "$HERE/natpmp.py" 192.168.77.1 "$@"; }
dnat_rules() { nft list chain inet mtest upnp_prerouting | grep -c dnat; }

# LAN side: a client namespace behind veth-gw; WAN side: a dummy interface
ip netns add $NS
ip link add veth-gw type veth peer name veth-c
ip link set veth-c netns $NS
ip addr add 192.168.77.1/24 dev veth-gw
ip link set veth-gw up
ip -n $NS addr add 192.168.77.2/24 dev veth-c
ip -n $NS link set veth-c up
ip -n $NS link set lo up
ip link add mupx0 type dummy
ip addr add 11.22.33.44/24 dev mupx0
ip link set mupx0 up

# same layout as OpenWrt fw4: base chains jumping to the upnp chains
nft -f - << 'EOF'
table inet mtest {
	chain upnp_forward {}
	chain upnp_prerouting {}
	chain upnp_postrouting {}
	chain churn {}
	chain forward { type filter hook forward priority filter; jump upnp_forward; }
	chain dstnat { type nat hook prerouting priority dstnat; jump upnp_prerouting; }
	chain srcnat { type nat hook postrouting priority srcnat; jump upnp_postrouting; }
}
EOF

cat > "$W/miniupnpd.conf" << 'EOF'
ext_ifname=mupx0
ext_ip=11.22.33.44
listening_ip=veth-gw
port=0
enable_upnp=no
enable_natpmp=yes
secure_mode=yes
system_uptime=yes
upnp_table_name=mtest
upnp_nat_table_name=mtest
upnp_forward_chain=upnp_forward
upnp_nat_chain=upnp_prerouting
upnp_nat_postrouting_chain=upnp_postrouting
upnp_nftables_family_split=no
uuid=fc4ec57e-b051-11db-88f8-0060085db3f6
allow 1024-65535 192.168.77.0/24 1024-65535
deny 0-65535 0.0.0.0/0 0-65535
EOF

"$BIN" -f "$W/miniupnpd.conf" -d > "$LOG" 2>&1 &
MUPD=$!
sleep 2
kill -0 $MUPD 2> /dev/null || { echo "miniupnpd did not start"; cat "$LOG"; exit 1; }

echo "== $N mappings"
client map 20000 "$N" 3600
echo "dnat rules: $(dnat_rules)"

echo "== churn the ruleset for ${CHURN_SECS}s while mappings come and go"
(while :; do nft add rule inet mtest churn counter; nft flush chain inet mtest churn; done) 2> /dev/null &
CHURN=$!
end=$((SECONDS + CHURN_SECS))
round=0
while [ $SECONDS -lt $end ]; do
	client map 40000 20 3600 > /dev/null
	client delete 40000 20 > /dev/null
	round=$((round + 1))
done
kill $CHURN; wait $CHURN 2> /dev/null; CHURN=
interrupted=$(grep -cE "mnl_cb_run returned|reopening the netlink socket" "$LOG")
echo "rounds=$round, failed or resynced netlink reads during churn: $interrupted"

sleep 2
mark=$(wc -l < "$LOG")
echo "== churn stopped: delete everything"
client delete 20000 "$N"
client delete 40000 20
client map 50000 1 3600
client delete 50000 1
left=$(dnat_rules)
errors=$(tail -n +"$((mark + 1))" "$LOG" | grep -c "mnl_cb_run returned")
echo "dnat rules left: $left, netlink errors after the churn: $errors"
tail -n +"$((mark + 1))" "$LOG" | grep -E "mnl_cb_run|netlink|FAILED" | head -5

if [ "$interrupted" -eq 0 ]; then
	echo "INCONCLUSIVE: no dump was interrupted"
	exit 2
fi
if [ "$left" -eq 0 ] && [ "$errors" -eq 0 ]; then
	echo PASS
	exit 0
fi
echo FAIL
exit 1
