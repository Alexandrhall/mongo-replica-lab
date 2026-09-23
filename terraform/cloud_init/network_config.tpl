version: 2
ethernets:
  # Matchar på namn-glob istället för hårdkodat ens3 (heter enp1s0 på q35-maskiner).
  primary:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - ${ip_address}/${prefix}
    routes:
      - to: default
        via: ${gateway}
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
