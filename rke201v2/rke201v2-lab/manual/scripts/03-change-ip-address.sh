sudo nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 172.30.170.3/24 \
  ipv4.gateway 172.30.170.1 \
  ipv4.dns "8.8.8.8,8.8.4.4"