#!/bin/bash

set -Eeuo pipefail

# use 1.1.1.1 in case there's no dns container up
echo "nameserver 1.1.1.1" > /etc/resolv.conf

if [ -f "/final/gravity.db" ]; then
	echo "using symbol link for /etc/pihole, as /final is already setup"
	rm /etc/pihole -rf
	ln -s /final /etc/pihole
elif [ ! -f "/etc/pihole/gravity.db" ]; then
	# run gravity to cause db to get created
	echo "creating gravity db"
	pihole -g
fi

### Allowlist items
# new sqlite approach based for PiHole v6
echo;
echo "Prepping allowlists"
echo "https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/whitelist.txt
https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/optional-list.txt
https://raw.githubusercontent.com/anudeepND/whitelist/master/domains/referral-sites.txt
https://tholinka.github.io/projects/hosts/allowlist" | sort > /tmp/allow.list

echo "getting current allowlists"
pihole-FTL sql /etc/pihole/gravity.db "SELECT address FROM adlist WHERE type=1" | sort > /tmp/current-allow.list

to_remove=$(comm -23 /tmp/current-allow.list /tmp/allow.list)
echo "Removing lists not in the combined allow lists from db: $to_remove"
echo "$to_remove" | xargs -I{} pihole-FTL sql /etc/pihole/gravity.db "DELETE FROM adlist WHERE address='{}' AND type=1;"

to_add="$(comm -13 /tmp/current-allow.list /tmp/allow.list)"
echo "Inserting new allow lists into db: $to_add"
echo "$to_add" | xargs -I{} pihole-FTL sql /etc/pihole/gravity.db "INSERT INTO adlist (address, comment, enabled, type) VALUES ('{}', 'allowlist, added `date +%F`', 1, 1);"

echo "Done with allowlist"

### Deny list items
# new sqlite approach based on https://discourse.pi-hole.net/t/blocklist-management-in-pihole-v5/31971/9
echo;
echo "getting current adlists"
pihole-FTL sql /etc/pihole/gravity.db "SELECT address FROM adlist WHERE type=0" | sort > /tmp/current.list

echo "Downloading adlist from wally3k.firebog.net"
curl "https://v.firebog.net/hosts/lists.php?type=tick" | sort > /tmp/firebog.list

echo "Adding tholinka.github.io tracking lists"

echo "https://tholinka.github.io/projects/hosts/wintracking/normal
https://tholinka.github.io/projects/hosts/hosts" | sort > /tmp/tholinka.list

cat /tmp/firebog.list /tmp/tholinka.list | sort > /tmp/combined.list

to_remove="$(comm -23 /tmp/current.list /tmp/combined.list)"
echo "Removing lists not in the combined lists from db: $to_remove"

echo "$to_remove" | xargs -I{} pihole-FTL sql /etc/pihole/gravity.db "DELETE FROM adlist WHERE address='{}' AND type=0;"

to_add="$(comm -13 /tmp/current.list /tmp/firebog.list)"
echo "Inserting new firebog lists into db: $to_add"
echo "$to_add" | xargs -I{} pihole-FTL sql /etc/pihole/gravity.db "INSERT INTO adlist (address, comment, enabled, type) VALUES ('{}', 'firebog, added `date +%F`', 1, 0);"

to_add="$(comm -13 /tmp/current.list /tmp/tholinka.list)"
echo "Inserting new tholinka.github.io lists into db: $to_add"
echo "$to_add" | xargs -I{} pihole-FTL sql /etc/pihole/gravity.db "INSERT INTO adlist (address, comment, enabled, type) VALUES ('{}', 'tholinka.github.io, added `date +%F`', 1, 0);"

echo;
echo "Running pihole gravity"
echo;

pihole -g

echo;
echo "Updating pihole.toml"

pihole-FTL --config misc.etc_dnsmasq_d true
pihole-FTL --config dns.blockESNI false
pihole-FTL --config dns.domain internal
pihole-FTL --config webserver.domain "pihole.${SECRET_DOMAIN}"

echo;
if [ -L /etc/pihole ]; then
	echo "skipping copying of config, as /etc/pihole is a symlink"
else
	echo "copying config to pihole container config"
	cp -a /etc/pihole/. /final
fi
