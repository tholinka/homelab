#!/bin/sh

# use 1.1.1.1 in case there's no dns container up
#echo "original resolv:" -n
#cat /etc/resolv.conf
#echo ""
#echo "nameserver 1.1.1.1" > /etc/resolv.conf

### Whitelist items
echo "Nuking existing allowlist"
pihole -r
pihole -w --nuke

pihole --help

# Add anudeepND's allowlist first, then add these on top of it
# from https://github.com/anudeepND/whitelist/blob/master/scripts/whitelist.sh#L28
echo "Downloading anudeepND's allowlist's"
curl -sS https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt > /tmp/allow
curl -sS https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/optional-list.txt >> /tmp/allow
curl -sS https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/referral-sites.txt >> /tmp/allow

echo "Adding more domains to allowlist"
curl -sS https://tholinka.github.io/projects/hosts/allowlist >> /tmp/allow

echo "Dedupping allowlist"
cat /tmp/allow | sed '/^[[:blank:]]*#/d;s/#.*//' | sed '/^[[:space:]]*$/d' | sort | uniq > /tmp/a


echo "Setting allowlist"
pihole -w $(cat /tmp/a)

echo "Done with allowlist"


# new sqlite approach based on https://discourse.pi-hole.net/t/blocklist-management-in-pihole-v5/31971/9
echo;
echo;
echo "removing old adlist"
sqlite3 /etc/pihole/gravity.db "DELETE FROM adlist"


echo "Downloading adlist from wally3k.firebog.net"
echo;
curl "https://v.firebog.net/hosts/lists.php?type=tick" | xargs -I {} sqlite3 /etc/pihole/gravity.db "INSERT INTO adlist (Address, Comment, Enabled) VALUES ('{}', 'firebog, added `date +%F`', 1);"

echo;
echo;
echo "Adding tholinka.github.io tracking lists"

echo "https://tholinka.github.io/projects/hosts/wintracking/normal
https://tholinka.github.io/projects/hosts/hosts" | xargs -I {} sqlite3 /etc/pihole/gravity.db "INSERT INTO adlist (Address, Comment, Enabled) VALUES ('{}', 'tholinka.github.io, added `date +%F`', 1);"

# let gravity run during startup
#echo;
#echo "Running pihole gravity"
#echo;

#pihole -g

# switch dns to pihole
echo "nameserver 127.0.0.1" > /etc/resolv.conf
