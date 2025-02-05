# Internal Network

## DNS
How my dns works:

- In the Unifi Network App, under Settings -> Internet -> WAN1 and WAN2. Set ipv6 dns to `192.168.20.6` and ipv6 to `fdaa:aaaa:aaaa:aa20::6`.
- The internal external-dns updates Unifi, Unifi points to Pihole, Pihole points to Dnscrypt-Proxy

## Unifi IPv6 ULA setup

Consolidated from here: https://github.com/unifi-utilities/unifios-utilities/issues/104#issuecomment-2259534906

ssh into Unifi gateway: `root@192.168.1.1`, configure your ssh cert in the Unifi Network App

```sh
curl -fsL "https://raw.githubusercontent.com/unifi-utilities/unifios-utilities/HEAD/on-boot-script-2.x/remote_install.sh" | /bin/bash
chmod -x /data/onboot.d0/5-install-cni-plugins.sh /data/onboot.d0/6-cni-bridge.sh

mkdir /data/ipv6-ula

tee /data/ipv6-ula/ensure-ula.sh << '_EOF'
#!/bin/bash

ULA_PREFIX="fdaa:aaaa:aaaa"

add_ula () {
  if [ -z "`ip address show dev $1 to $ULA_PREFIX:$2::/64`" ]
  then
    ip address add $ULA_PREFIX:$2::1/64 dev $1
  fi
}

add_ula br0 aa00
add_ula br20 aa20
add_ula br30 aa30

ADDEDDNSMASQ=0

# only add entry to dnsmasq config if it does not exist
add_dnsmasq () {
  conf=$(find /run/dnsmasq.conf.d/ -type f -name "*$1*IPV6.conf")
  if [ -z "`grep ra-names $conf`" ]
  then
    sed -i 's/ra-only/ra-names/g' $conf
    echo "Changed to ra-names"
    ADDEDDNSMASQ=1
  fi
}

#add_dnsmasq br0
#add_dnsmasq br20
#add_dnsmasq br30

# Use single brackets for compatibility
if [ "$ADDEDDNSMASQ" = "1" ]; then
  pkill dnsmasq
fi
_EOF

chmod a+x /data/ipv6-ula/ensure-ula.sh

tee /data/on_boot.d/17-ula.sh << '_EOF'
#!/bin/sh

echo "* * * * * root /bin/bash -c 'sh /data/ipv6-ula/ensure-ula.sh'" > /etc/cron.d/ula
_EOF

chmod a+x /data/on_boot.d/17-ula.sh

```
