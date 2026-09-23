# WSL-varianten av terraform-labbet

Samma 3 VM:ar som `../`, men med ett **eget Terraform-state** i den här katalogen och en
uppsättning kontroller för att köra KVM/libvirt inuti WSL2. `../main.tf` och `../variables.tf`
är oförändrade — den här mappen anropar dem som en modul.

> **Kör från en katalog i taget.** Domänerna heter `mongo-node-1..N` oavsett varifrån du kör,
> så `../` och den här mappen krokar i samma libvirt-objekt. Har du redan applyat i `../`:
> gör `terraform destroy` där först.

Fungerar det över huvud taget i WSL? Ja. Nested virtualization är aktiv på den här maskinen
(`/dev/kvm` finns, `kvm_amd` är laddad), systemd kör som PID 1 och kärnan har tun, bridge,
nf_nat och cgroup v2. Det som återstår är paket, gruppmedlemskap och RAM.

## 0. Förutsättningar

- `/dev/kvm` måste finnas (uppfyllt här).
- WSL-instansen behöver ledigt RAM som täcker `node_count × memory_mb` plus overhead —
  med defaulterna 3 × 2048 MB = 6 GB. `./preflight.sh` räknar och säger till.
- En SSH-nyckel: `ssh-keygen -t ed25519` om du saknar en.

## 1. Paket (Debian 13 trixie)

```bash
sudo apt update
sudo apt install -y qemu-system-x86 qemu-system-modules-spice qemu-utils \
                    libvirt-daemon-system libvirt-clients dnsmasq-base virtinst genisoimage
sudo usermod -aG libvirt,kvm "$USER"
```

`qemu-system-modules-spice` är **inte** valfritt: Debian 13 har brutit ut SPICE-stödet ur
`qemu-system-x86`, och `../main.tf` har ett `graphics { type = "spice" }`-block. Utan modulen
vägrar domänerna starta.

Gruppändringen slår igenom först efter `wsl --shutdown` och en ny terminal.

Bekvämlighet i `~/.zshrc`, annars behöver varje `virsh` ett `-c qemu:///system`:

```bash
export LIBVIRT_DEFAULT_URI=qemu:///system
```

## 2. Terraform

HashiCorps apt-repo har ingen `trixie`-suite ännu, så binären är enklast:

```bash
mkdir -p ~/.local/bin
TF=$(curl -fsSL https://api.github.com/repos/hashicorp/terraform/releases/latest \
     | grep -oP '"tag_name": "v\K[^"]+')
curl -fsSLo /tmp/tf.zip \
     "https://releases.hashicorp.com/terraform/${TF}/terraform_${TF}_linux_amd64.zip"
unzip -o /tmp/tf.zip -d ~/.local/bin && terraform version
```

OpenTofu går lika bra — modulen kräver bara `>= 1.5.0`.

## 3. libvirtd, nätverk och pool

```bash
sudo systemctl enable --now libvirtd

virsh net-list --all
virsh net-start default && virsh net-autostart default

virsh pool-list --all
# saknas poolen helt:
virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-start default && virsh pool-autostart default
```

Poolen ska ligga på ext4 inuti WSL (`/var/lib/libvirt/images`). Lägg **aldrig** qcow2-filerna
under `/mnt/c` — 9p mot Windows gör VM-I/O outhärdligt långsamt.

## 4. AppArmor — bara om det failar

WSL-kärnan har ingen AppArmor. Debians libvirt autodetekterar säkerhetsdrivrutin och brukar
klara sig, men om domäner vägrar starta och `journalctl -u libvirtd` nämner `virt-aa-helper`:

```
# /etc/libvirt/qemu.conf
security_driver = "none"
```

följt av `sudo systemctl restart libvirtd`.

## 5. Kör

```bash
./preflight.sh                                  # read-only, ändrar ingenting

cp terraform.tfvars.example terraform.tfvars    # fyll i ssh_public_key
terraform init

terraform apply -var node_count=1               # rökprov med en nod först
virsh console mongo-node-1                      # bara titta på booten, ^] för att lämna.
                                                # login: kräver lösenord och ubuntu har inget - logga in med ssh
ping -c3 192.168.122.101
ssh ubuntu@192.168.122.101 'grep -c avx /proc/cpuinfo'   # >0 = host-passthrough ger AVX
ssh ubuntu@192.168.122.101 cloud-init status --wait     # väntar tills cloud-init är klar

terraform apply                                 # skala upp till 3 noder
terraform output -raw ansible_inventory > ../../ansible/inventory/hosts.ini
```

Rökprovet med en nod är inte överdrift: det är där de två WSL-känsliga sakerna visar sig —
att qemu får starta alls, och att `cpu { mode = "host-passthrough" }` verkligen släpper
igenom AVX (mongod 5.0+ dör annars med SIGILL).

## 6. Vidare

Resten följer rot-README:t (`../../README.md`) oförändrat — `init_replica_set.yml`,
`status.yml`, `seed.yml`, `verify.yml`, `rolling_upgrade.yml`.

Ansible körs **från WSL**: 192.168.122.0/24 är libvirts NAT-nät och syns bara inifrån
WSL-instansen, inte från Windows. Stoppa gärna docker-labbet (`../../docker/lab.sh down`)
medan VM:arna kör, så slåss de inte om minnet.

## 7. Städning

```bash
terraform destroy
```

Det frigör qcow2-filerna i poolen, men WSL:s VHDX på Windows-sidan krymper inte av sig själv.
Vill du ha tillbaka utrymmet får du kompaktera den därifrån.

## Felsökning

| Symptom | Orsak / åtgärd |
|---|---|
| `Could not access KVM kernel module` | du är inte i gruppen `kvm`, eller WSL inte omstartad efter `usermod` |
| `spice is not supported by this QEMU binary` | `qemu-system-modules-spice` saknas (steg 1) |
| `virt-aa-helper`-fel i `journalctl -u libvirtd` | AppArmor saknas i WSL-kärnan → `security_driver = "none"` (steg 4) |
| `Permission denied` mot `qemu:///system` | gruppen `libvirt` saknas, eller `libvirtd` kör inte |
| `Error creating libvirt domain: ... network 'default' is not active` | `virsh net-start default` |
| VM:ar fryser, OOM-killer slår till | `node_count × memory_mb` överstiger ledigt RAM; docker-labbet kör samtidigt |
| Cloud-init hänger, ingen IP | `virsh console mongo-node-1` och läs — oftast fel `ssh_public_key` i `terraform.tfvars` |
| Konstig klocka efter att Windows sovit | `sudo hwclock -s` |
| `exec: "mkisofs": executable file not found in $PATH` | `sudo apt install genisoimage` — providern bygger cloud-init-ISO:n med `mkisofs` |

## Filerna här

| Fil | Roll |
|---|---|
| `main.tf` | wrapper, `module "lab" { source = "../" }` |
| `variables.tf` | samma variabler som roten, defaults `3 / 2048 MB / 2 vCPU / 20 GB` |
| `outputs.tf` | `node_names`, `node_ips`, `ansible_inventory` vidarebefordrade |
| `terraform.tfvars.example` | mall, kopiera till `terraform.tfvars` |
| `preflight.sh` | read-only kontroll av kvm, grupper, paket, libvirt-nät/pool och RAM |
