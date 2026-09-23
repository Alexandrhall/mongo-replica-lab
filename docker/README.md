# docker/ – 3-nods replica set i Docker (för test i WSL)

Simulerar 3-nodslösningen från `../terraform` + `../ansible` med tre containrar
(`mongo-node-1..3`) i stället för tre VM:ar. Ansible körs lokalt och styr containrarna via
`docker exec`. Samma upplägg som VM-varianten: init → `rs0` → rolling upgrade.

Kräver bara `docker` och `ansible` (med `community.docker`, som redan finns) – ingen Python-SDK behövs.

## Snabbstart

```bash
cd docker
./lab.sh up                 # 3 x mongo:5.0 + rs.initiate(rs0)
./lab.sh status             # version per nod, rs.status(), FCV

./lab.sh upgrade 6.0        # rolling upgrade 5.0 -> 6.0 (+ FCV 6.0)
./lab.sh upgrade 7.0        # rolling upgrade 6.0 -> 7.0 (+ FCV 7.0)
./lab.sh upgrade 8.0        # rolling upgrade 7.0 -> 8.0 (+ FCV 8.0)

./lab.sh resync-test        # ALLT-I-ETT: skriv data medan en nod är nere, starta den, verifiera att den synkat
./lab.sh seed               # testdata: 3 collections x 30 dokument i databasen labdb
./lab.sh verify             # kontrollera att datan finns kvar och är identisk på varje nod

./lab.sh stop mongo-node-2  # stoppa en nod snyggt (SIGTERM)   | ./lab.sh kill mongo-node-2 = krasch (SIGKILL)
./lab.sh start mongo-node-2 # starta den igen

./lab.sh dump               # mongodump av labdb -> dumps/labdb_<version>_<tid>.archive.gz
./lab.sh restore            # mongorestore av senaste dumpen in i klustret + jämför antal/index + verify
./lab.sh migrate 8.0        # dump -> riv klustret -> nytt kluster med 8.0 -> restore -> verify (hoppar över majors)

./lab.sh shell              # mongosh i mongo-node-1
./lab.sh down               # ta bort containrar (data sparas i volymer)
./lab.sh purge              # ta bort allt inklusive data
```

Utan wrapper: `ansible-playbook up.yml`, `ansible-playbook upgrade.yml -e target_version=7.0`, osv.

## Testdata och nodstopp

`seed` skriver deterministisk data (`users`, `products`, `orders` × 30 dokument, plus index på `email`,
`sku` och `userId`) mot replica setet med `w: majority`, så det fungerar även när en nod är nere.
`verify` läser **direkt från varje nod som kör** (även secondaries), jämför varje dokument fält för fält mot
det seed genererar och kontrollerar indexen. Stoppade noder hoppas över och rapporteras som `NERE`.
Resultatet ser ut så här:

```
mongo-node-1: OK PRIMARY {'users': 30, 'products': 30, 'orders': 30}
mongo-node-2: OK SECONDARY {...}
mongo-node-3: NERE (hoppades över)
```

### Ett kommando: skriv medan en nod är nere, starta den, se att den synkar

```bash
./lab.sh resync-test               # stoppar mongo-node-1 (oftast primary -> failover), default
./lab.sh resync-test mongo-node-3  # stoppa en annan nod
./lab.sh resync-test mongo-node-2 kill   # hård krasch (SIGKILL) i stället för snyggt stopp
```

Stegen: (1) seed 30 dokument/collection (databasen `labdb` droppas först) + verify på alla noder →
(2) stoppa noden → (3) skriv 40 dokument/collection medan den är nere (10 nya, och en del `orders` skrivs om, så
både inserts och updates ska replikeras) → (4) verify på de två noder som kör → (5) `docker start` →
(6) verify att **alla 3** noder har exakt samma 40 dokument (verify väntar upp till 60 s på att noden
kommer ikapp) → (7) status. Slutar med `RESYNC-TEST OK` eller ett fel som pekar ut vad som saknas.
Kördes med lyckat resultat mot 6.0 med primary nedstängd (ny primary valdes, skrivningen gick igenom, och
`mongo-node-1` tog tillbaka primary på egen hand när den kom tillbaka - se nästa avsnitt).

### Föredragen primary (`./lab.sh primary`)

`up` sätter `mongo-node-1` som **föredragen primary** (`priority: 2`, övriga `1`). Det är en vanlig
inställning i replica setet: efter ett stopp tar MongoDB tillbaka primary till den noden så fort den är uppe
och ikapp ("priority takeover"). Utan prioriteter blir den som råkade väljas primary kvar tills den själv faller.

```bash
./lab.sh primary                 # flytta primary till mongo-node-1 (default), tar några sekunder
./lab.sh primary mongo-node-2    # flytta till nod 2 - och gör den till föredragen, så den tar tillbaka rollen
./lab.sh status                  # visar prioriteter ("Prioritet: ...") och vem som är PRIMARY
```

- Ändringen ligger kvar i replica setet: `./lab.sh primary mongo-node-2` betyder "nod 2 ska vara primary
  när den kan". Kör `./lab.sh primary` för att gå tillbaka till nod 1.
- Målnoden måste köra. Är den stoppad får du ett tydligt felmeddelande - starta den först.
- Vill du testa *utan* föredragen primary (ingen återtagning)? Sätt lika prioritet:
  `docker exec mongo-node-1 mongosh --quiet --eval 'c=rs.conf(); c.members.forEach(m=>m.priority=1); rs.reconfig(c)'`
  (nästa `./lab.sh up` eller `./lab.sh primary` sätter tillbaka den föredragna).
- Ett kluster som startades före den här funktionen har lika prioritet; kör `./lab.sh up` eller
  `./lab.sh primary` en gång så sätts de.

### Manuellt, steg för steg

```bash
./lab.sh seed && ./lab.sh verify                 # baslinje

./lab.sh stop mongo-node-1                       # stoppa primary -> ny primary väljs
./lab.sh status                                  # fungerar även med nod 1 nere
./lab.sh seed 40 && ./lab.sh verify 40           # skriv MEDAN en nod är nere (2 av 3 = majoritet)
./lab.sh start mongo-node-1                      # noden kommer tillbaka, replikerar ikapp och tar tillbaka primary
./lab.sh verify 40                               # alla 3 noder ska ha de 40 dokumenten

./lab.sh kill mongo-node-3                       # hård krasch, samma flöde
./lab.sh stop mongo-node-2 && ./lab.sh stop mongo-node-3   # 1 av 3 kvar: ingen majoritet -> ingen primary,
                                                 # seed misslyckas (som det ska). Starta nod 2 igen så funkar det.
./lab.sh upgrade 7.0 && ./lab.sh verify          # datat överlever en rolling upgrade
```

- `seed` är idempotent (upsert på `_id`). Flaggor: `-e reset=true` droppar databasen först,
  `-e seed_db=annan` byter databas. `verify` måste få samma antal som du seedade (`./lab.sh verify 40`).
- Obs: `orders` refererar till `users`/`products` via modulo på antalet, så att seeda ett annat antal
  skriver om en del `orders`. Vill du börja om från 30: `./lab.sh seed 30 -e reset=true`.
- Uppgraderingen (`upgrade`) kräver ett friskt kluster med alla 3 noder uppe – starta stoppade noder först.

## Uppgradera via dump/restore (hoppa över major-versioner)

Alternativ till rolling upgrade: exportera datat, bygg ett **nytt** kluster med målversionen och läs in det.
Då behövs inga FCV-steg och man kan gå direkt, t.ex. 5.0 → 8.0.

```bash
./lab.sh up 5.0 && ./lab.sh seed 50          # 1. kluster på 5.0 med data (eller din egen data i labdb)
./lab.sh migrate 8.0 --dry-run               # 2. valfritt: bara dumpen, visar vad som skulle hända
./lab.sh migrate 8.0                         # 3. dump -> bekräfta ("ja") -> purge -> up 8.0 -> restore -> verify
```

Eller steg för steg:

```bash
./lab.sh dump                                # från det körande klustret (ändrar inget). --db: ./lab.sh dump annan_db
./lab.sh purge && ./lab.sh up 8.0            # klustret MÅSTE nollställas: mongod 8.0 startar inte på 5.0-datafiler
./lab.sh restore                             # senaste dumpen (eller ./lab.sh restore dumps/<fil>)
```

- **Dumpen** (`dumps/<db>_<version>_<tid>.archive.gz` + `.json` med antal dokument och index) ligger på värden
  och överlever `purge`. Den skapas med `mongodump --archive --gzip` direkt till en fil.
- **Restore** kör `mongorestore --drop --writeConcern=majority` med verktygen från *målets* image, och jämför sedan
  antal dokument och index mot dumpen. För `labdb` körs också `verify` (fält för fält, alla noder) med rätt antal.
- `migrate` frågar innan den river något (`ja`), eller `--yes`. Dumpen finns kvar om något går fel.
- **Skillnad mot rolling upgrade:** dump/restore har **nedtid** (klustret rivs och byggs om) och tar bara med den
  databas du dumpar (`labdb`) - inte andra databaser, användare eller inställningar. Rolling upgrade
  har ingen nedtid men går bara ett major-steg åt gången.
- **Varning från MongoDB:** vid cross-version restore skriver `mongorestore` ut att det är "unsupported" och att datat
  "may be corrupted". I labbet (5.0 → 8.0, 120 dokument + index) blev datat identiskt fält för fält, men det bevisar
  inte att det är säkert för stor eller komplex data. Verktyget står bakom varningen; det officiellt stödda
  sättet mellan major-versioner är rolling upgrade.

## Rolling upgrade

`target_version` är **obligatorisk** (`-e target_version=7.0`). Tag på Docker Hub: `7.0` (senaste 7.0.x)
eller exakt, t.ex. `7.0.14`. Playbooken:

1. **Validerar innan något ändras:** ingen nedgradering, bara *ett* major-steg åt gången
   (5.0 → 6.0 → 7.0 → 8.0; `./lab.sh upgrade 7.0` direkt från 5.0 nekas), FCV måste stå på nuvarande major,
   klustret måste vara friskt, målimagen hämtas.
2. Uppgraderar **secondaries en och en, sist primary** (stegas ner först). Per nod: vänta på friskt kluster →
   stepDown → byt container till nya imagen → vänta tills noden är `SECONDARY`/`PRIMARY` med lag ≤ 10 s.
3. När **alla** noder kör nya binärer höjs `featureCompatibilityVersion` (körs på primary,
   `confirm: true` för 7.0+). Utan det nekas nästa major-steg. Hoppa över med `-e set_fcv=false`;
   kör om utan flaggan för att höja den senare.
4. Idempotent – noder som redan kör målversionen hoppas över, så en avbruten körning kan köras om.

Testa att datat överlever uppgraderingarna:

```bash
./lab.sh shell      # db.test.insertOne({a: 1})  ... uppgradera ... db.test.find()
```

## Minne (WSL ~4 GB)

Varje container får `--wiredTigerCacheSizeGB 0.25`, `--oplogSize 128` och ett tak på 600 MB
(`group_vars/all.yml`: `mongo_wt_cache_gb`, `mongo_oplog_size_mb`, `mongo_container_memory`).
Tre noder bör landa runt 1–1,5 GB totalt (uppskattning, ej uppmätt). Blir en nod OOM-dödad
(`docker inspect mongo-node-1 --format '{{.State.OOMKilled}}'`) – höj `mongo_container_memory`.
Diskutrymme: imagerna för 5.0, 6.0, 7.0 och 8.0 är några hundra MB var.

## Övrigt

- Noderna når varandra via containernamn på nätverket `mongo-lab` (medlemmar = `mongo-node-N:27017`).
  Portarna publiceras även på `127.0.0.1:27017/27018/27019`, men replica setet annonserar containernamnen,
  så anslut från WSL med `mongodb://127.0.0.1:27017/?directConnection=true`.
- Startversion ändras med `./lab.sh up 7.0` eller `mongodb_initial_version` i `group_vars/all.yml`.
- Fler major-versioner läggs till i `mongo_major_sequence` (`group_vars/all.yml`).
- Ingen auth (labb). 5.0 och 6.0 är end-of-life men imagerna finns kvar på Docker Hub.
