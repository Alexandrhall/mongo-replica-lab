# mongo-replica-lab

3 Ubuntu 24.04-VM:ar på KVM/libvirt (Terraform), MongoDB i Docker, replica set `rs0` (Ansible),
testdata, föredragen primary och rolling upgrade av Mongo-versionen.

```
docker/      Samma labb lokalt med 3 Docker-containrar (test i WSL, se docker/README.md)
terraform/   3 VM:ar (cloud-init, statiska IP .101-.103, host-passthrough-CPU för AVX)
ansible/     init_replica_set.yml  -> Docker + mongo:<initial> på alla noder, rs.initiate() med prioriteter
             status.yml            -> version per nod, rs.status(), prioriteter och FCV
             seed.yml / verify.yml -> deterministisk testdata, och kontroll att den är identisk på varje nod
             primary.yml           -> flytta primary till en vald nod (föredragen primary)
             rolling_upgrade.yml   -> uppgradera till mongo:<target>, secondaries först, primary sist
```

## Förutsättningar (på maskinen du kör från)

- `terraform >= 1.5`, `ansible` + `community.docker` (`ansible-galaxy collection install -r ansible/requirements.yml`)
- libvirt + qemu-kvm, `libvirtd` igång, din användare i grupperna `libvirt` och `kvm`
- libvirt-poolen `default` och nätverket `default` (192.168.122.0/24) aktiva:
  `virsh pool-list --all`, `virsh net-list --all` (starta med `virsh net-start default`, `virsh pool-start default`)
- En SSH-nyckel: `ssh-keygen -t ed25519` (den publika nyckeln läggs in i alla noder)
- WSL2: kräver nested virtualization (`/dev/kvm` måste finnas) och systemd. Nätverket 192.168.122.0/24
  nås bara inifrån WSL.

Alla `ansible-playbook`-kommandon nedan körs från katalogen `ansible/` (det är där `ansible.cfg` ligger).

## Körordning

```bash
# 1. VM:ar
cd terraform
cp terraform.tfvars.example terraform.tfvars      # fyll i ssh_public_key
terraform init && terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory/hosts.ini   # bara om du ändrat IP/antal

# 2. Replica set (vänta ~1 min efter apply så cloud-init hinner klart; playbooken väntar också)
cd ../ansible
ansible mongo_replica -m ping
ansible-playbook playbooks/init_replica_set.yml   # installerar mongo:5.0 och skapar rs0
ansible-playbook playbooks/status.yml             # versioner, PRIMARY, prioriteter, FCV

# 3. Testdata
ansible-playbook playbooks/seed.yml               # 3 collections x 30 dokument i databasen labdb
ansible-playbook playbooks/verify.yml             # samma data på varje nod som kör?

# 4. Rolling upgrade, en major i taget (inkl. featureCompatibilityVersion). Målversionen är obligatorisk.
ansible-playbook playbooks/rolling_upgrade.yml -e target_version=6.0
ansible-playbook playbooks/rolling_upgrade.yml -e target_version=6.0   # igen: alla noder hoppas över (idempotent)
ansible-playbook playbooks/verify.yml                                  # datat överlever uppgraderingen
```

Varianter av steg 4:

```bash
ansible-playbook playbooks/rolling_upgrade.yml -e target_version=8.0.29              # exakt patch-version
ansible-playbook playbooks/rolling_upgrade.yml -e target_version=7.0 -e set_fcv=false   # uppgradera binärer, låt FCV vara kvar
```

Startversionen styrs av `mongodb_initial_version` i `ansible/inventory/group_vars/mongo_replica.yml`, och
målversionen av `-e target_version=`. Båda måste vara existerande tags på Docker Hub (`mongo:<version>`).

## Testdata (`seed` / `verify`)

`seed` skriver deterministisk data (`users`, `products`, `orders` × 30 dokument, plus index på `email`,
`sku` och `userId`) mot replica setet med `w: majority`, så det fungerar även när en nod är nere.
`verify` läser **direkt från varje nod som kör** (även secondaries), jämför varje dokument fält för fält
mot det seed genererar och kontrollerar indexen. Noder som är nere hoppas över och rapporteras:

```
mongo-node-1: OK PRIMARY {'users': 30, 'products': 30, 'orders': 30}
mongo-node-2: OK SECONDARY {...}
mongo-node-3: NERE (hoppades över)
```

```bash
ansible-playbook playbooks/seed.yml -e seed_docs_per_collection=50   # växer till 50 (befintliga rörs inte)
ansible-playbook playbooks/verify.yml -e seed_docs_per_collection=50 # verify måste få samma antal som du seedade
ansible-playbook playbooks/seed.yml -e reset=true                    # droppa databasen först
ansible-playbook playbooks/seed.yml -e seed_db=annan_db
```

- `seed` är idempotent (upsert på `_id`).
- Obs: `orders` refererar till `users`/`products` via modulo på antalet, så att seeda ett annat antal
  skriver om en del `orders`. Vill du börja om från 30: `-e seed_docs_per_collection=30 -e reset=true`.

## Föredragen primary (`primary.yml`)

`init_replica_set.yml` sätter `mongo-node-1` som **föredragen primary** (`priority: 2`, övriga `1`). Efter
ett stopp tar MongoDB tillbaka primary till den noden så fort den är uppe och ikapp ("priority takeover").
Utan prioriteter blir den som råkade väljas primary kvar tills den själv faller.

```bash
ansible-playbook playbooks/primary.yml                                     # tillbaka till mongo-node-1
ansible-playbook playbooks/primary.yml -e mongo_preferred_primary=mongo-node-2
ansible-playbook playbooks/status.yml                                      # visar prioriteter och vem som är PRIMARY
```

Ändringen ligger kvar i replica setet. Målnoden måste köra — är den nere får du ett felmeddelande med
kommandot för att starta den.

## Stoppa och starta noder

Till skillnad från docker-labbet görs det manuellt på maskinerna, eftersom det är tre separata VM:ar:

```bash
ssh ubuntu@192.168.122.102 sudo docker stop -t 60 mongo   # snyggt stopp (SIGTERM)
ssh ubuntu@192.168.122.102 sudo docker kill mongo         # hård krasch (SIGKILL)
ssh ubuntu@192.168.122.102 sudo docker start mongo
virsh shutdown mongo-node-2                               # eller stäng av hela VM:en
```

`status.yml` och `verify.yml` klarar både en stoppad container och en avstängd VM — noden rapporteras som
`NERE` respektive `VM:EN SVARAR INTE` och hoppas över. `seed.yml` skriver med `w: majority`, så det
fungerar så länge 2 av 3 noder kör. `rolling_upgrade.yml` kräver däremot ett friskt kluster med alla
3 noder uppe.

```bash
ssh ubuntu@192.168.122.102 sudo docker stop -t 60 mongo
ansible-playbook playbooks/status.yml                                  # nod 2 = NERE, ny primary vald
ansible-playbook playbooks/seed.yml -e seed_docs_per_collection=40     # skriv MEDAN en nod är nere
ansible-playbook playbooks/verify.yml -e seed_docs_per_collection=40   # nod 2 hoppas över
ssh ubuntu@192.168.122.102 sudo docker start mongo
ansible-playbook playbooks/verify.yml -e seed_docs_per_collection=40   # alla 3 noder har de 40 dokumenten
```

## Rolling upgrade

`target_version` är **obligatorisk**. Tag på Docker Hub: `7.0` (senaste 7.0.x) eller exakt, t.ex. `7.0.14`.
Playbooken:

1. **Validerar innan något ändras:** ingen nedgradering, bara *ett* major-steg åt gången
   (5.0 → 6.0 → 7.0 → 8.0), FCV måste stå på nuvarande major, klustret måste vara friskt,
   målimagen hämtas på alla noder.
2. Uppgraderar **secondaries en och en, sist primary** (stegas ner först). Per nod: vänta på friskt kluster →
   stepDown → byt container till nya imagen → vänta tills noden är `SECONDARY`/`PRIMARY` med lag ≤ 10 s.
3. När **alla** noder kör nya binärer höjs `featureCompatibilityVersion` (körs på den nod som är primary
   just då, `confirm: true` för 7.0+). Utan det nekas nästa major-steg. Hoppa över med `-e set_fcv=false`;
   kör om utan flaggan för att höja den senare.
4. Idempotent – noder som redan kör målversionen hoppas över, så en avbruten körning kan köras om.

## Begränsningar

- Ingen auth/keyFile (labb). Sätt `mongo_auth_args` i `ansible/inventory/group_vars/mongo_replica.yml`
  om du lägger till det.
- Rolling upgrade tar en major i taget enligt `mongo_major_sequence` (5.0 → 6.0 → 7.0 → 8.0). Att hoppa över
  en major eller nedgradera nekas innan något ändras. Nya majors läggs till i `mongo_major_sequence`.
- Docker-labbets `dump`/`restore`/`migrate` (uppgradering via dump/restore, som kan hoppa över majors) och
  `resync-test` finns bara i `docker/`, inte för VM:arna.
- Att riva klustret på VM-sidan görs med `terraform destroy` (eller `docker rm -f mongo` + `rm -rf
  /var/lib/mongo-data /var/lib/mongo-config` på varje nod om du bara vill nollställa MongoDB).
- De statiska IP:erna .101-.103 ligger inom libvirts DHCP-range; kolla att inget annat på nätet fått dem.
