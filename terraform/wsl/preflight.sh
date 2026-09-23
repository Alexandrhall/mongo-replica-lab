#!/usr/bin/env bash
# Read-only kontroller inför första "terraform apply" i WSL. Ändrar ingenting.
# Exit 0 = klart att köra, 1 = något måste åtgärdas. Varningar fäller inte körningen.
set -uo pipefail

VIRSH=(virsh -c qemu:///system)
fail=0
warn=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFEL\033[0m   %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33mVARN\033[0m  %s\n' "$1"; warn=$((warn + 1)); }
head_() { printf '\n%s\n' "$1"; }

# --- Värden -----------------------------------------------------------------
# Defaults speglar variables.tf; terraform.tfvars vinner om den sätter värdena.
node_count=3
memory_mb=2048
if [[ -f terraform.tfvars ]]; then
  v=$(grep -oP '^\s*node_count\s*=\s*\K[0-9]+' terraform.tfvars | tail -1) && [[ -n $v ]] && node_count=$v
  v=$(grep -oP '^\s*memory_mb\s*=\s*\K[0-9]+' terraform.tfvars | tail -1) && [[ -n $v ]] && memory_mb=$v
fi
need_mb=$((node_count * memory_mb))

head_ "Virtualisering"
if [[ -e /dev/kvm ]]; then
  if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ok "/dev/kvm finns och är läs-/skrivbar"
  else
    bad "/dev/kvm finns men du saknar rättigheter (gruppen kvm)"
  fi
else
  bad "/dev/kvm saknas - nested virtualization är inte aktiv"
fi
grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo \
  && ok "CPU exponerar vmx/svm" \
  || bad "CPU exponerar varken vmx eller svm"
grep -qE '^flags.*\bavx\b' /proc/cpuinfo \
  && ok "AVX finns på värden (mongod 5.0+ kräver det via host-passthrough)" \
  || note "AVX saknas på värden - mongod 5.0+ dör med SIGILL i gästerna"

head_ "Grupper"
groups=$(id -nG)
for g in libvirt kvm; do
  [[ " $groups " == *" $g "* ]] \
    && ok "du är med i gruppen $g" \
    || bad "du saknar gruppen $g (usermod -aG $g \$USER + starta om WSL)"
done

head_ "Paket och binärer"
for b in terraform virsh qemu-system-x86_64; do
  command -v "$b" >/dev/null \
    && ok "$b: $(command -v "$b")" \
    || bad "$b saknas"
done
command -v mkisofs >/dev/null \
  && ok "mkisofs: $(command -v mkisofs) (libvirt_cloudinit_disk bygger ISO:n med den)" \
  || bad "mkisofs saknas - libvirt_cloudinit_disk failar (sudo apt install genisoimage)"
if command -v dpkg >/dev/null; then
  dpkg -s qemu-system-modules-spice >/dev/null 2>&1 \
    && ok "qemu-system-modules-spice installerat (krävs av graphics{type=spice} i ../main.tf)" \
    || bad "qemu-system-modules-spice saknas - domänstarten failar på SPICE i Debian 13"
fi

head_ "libvirt"
if systemctl is-active --quiet libvirtd 2>/dev/null; then
  ok "libvirtd kör"
elif systemctl is-active --quiet virtqemud 2>/dev/null; then
  ok "virtqemud kör (modulär libvirt)"
else
  bad "varken libvirtd eller virtqemud är aktiv"
fi

if command -v virsh >/dev/null && "${VIRSH[@]}" version >/dev/null 2>&1; then
  ok "kan ansluta till qemu:///system utan sudo"

  if grep -qi '^Active:\s*yes' <<<"$("${VIRSH[@]}" net-info default 2>/dev/null)"; then
    ok "nätverket 'default' är aktivt"
    cidr=$("${VIRSH[@]}" net-dumpxml default 2>/dev/null \
           | grep -oP "address='\K192\.168\.\d+\.1(?=')" | head -1)
    [[ $cidr == 192.168.122.1 ]] \
      && ok "subnätet är 192.168.122.0/24 (matchar network_cidr i ../variables.tf)" \
      || note "gatewayen är ${cidr:-okänd}, inte 192.168.122.1 - sätt network_cidr därefter"
  else
    bad "nätverket 'default' är inte aktivt (virsh net-start default)"
  fi

  if grep -qi '^State:\s*running' <<<"$("${VIRSH[@]}" pool-info default 2>/dev/null)"; then
    ok "poolen 'default' kör"
    target=$("${VIRSH[@]}" pool-dumpxml default 2>/dev/null | grep -oP '<path>\K[^<]+')
    [[ $target == /mnt/* ]] \
      && note "poolen ligger på $target - 9p mot Windows gör VM-I/O mycket långsamt" \
      || ok "poolen ligger på ${target:-?}"
  else
    bad "poolen 'default' kör inte (virsh pool-start default)"
  fi

  existing=$("${VIRSH[@]}" list --all --name 2>/dev/null | grep -c '^mongo-node-')
  if [[ $existing -gt 0 && ! -f terraform.tfstate ]]; then
    note "$existing domän(er) mongo-node-* finns redan men inte i det här statet - kör du från ../ också?"
  else
    ok "inga oväntade mongo-node-domäner"
  fi
else
  bad "kan inte ansluta till qemu:///system (grupp, socket eller libvirtd)"
fi

head_ "Minne"
avail_mb=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
total_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
printf '  %s\n' "node_count=$node_count x memory_mb=$memory_mb -> ${need_mb} MB behövs, ${avail_mb} MB ledigt av ${total_mb} MB"
if [[ $avail_mb -ge $need_mb ]]; then
  ok "tillräckligt med ledigt RAM"
else
  note "för lite ledigt RAM - sänk memory_mb/node_count, stoppa docker-labbet, eller ge WSL mer"
fi

head_ "Resultat"
if [[ $fail -gt 0 ]]; then
  printf '  %d fel, %d varning(ar) - åtgärda felen först (se README.md).\n\n' "$fail" "$warn"
  exit 1
fi
printf '  Klart att köra: terraform init && terraform apply -var node_count=1  (%d varning(ar))\n\n' "$warn"
