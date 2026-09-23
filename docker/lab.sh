#!/usr/bin/env bash
# Wrapper runt ansible-playbook för 3-nods MongoDB-labbet i Docker.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<USAGE
Användning: ./lab.sh <kommando> [args]

  up [version]         Starta 3 containrar + initiera rs0 (default: mongodb_initial_version i group_vars/all.yml,
                       t.ex. ./lab.sh up 7.0)
                       mongo-node-1 blir föredragen primary (priority 2)
  upgrade <version>    Rolling upgrade till målversion, t.ex. ./lab.sh upgrade 7.0
                       (extra flaggor vidarebefordras, t.ex. -e set_fcv=false)
  status               Version per nod, rs.status(), prioriteter och FCV
  primary [nod]        Flytta primary till en nod (default mongo-node-1). Gör den till föredragen primary,
                       så den tar tillbaka rollen efter ett stopp. T.ex. ./lab.sh primary mongo-node-2
  seed [antal]         Fyll databasen med testdata: 3 collections x 30 dokument (eller [antal] per collection)
                       (extra flaggor vidarebefordras, t.ex. -e reset=true för att börja om)
  verify [antal]       Kontrollera att testdatan finns kvar och är identisk på varje nod som kör.
                       [antal] = samma antal du seedade (default 30): efter ./lab.sh seed 50 kör du ./lab.sh verify 50
  stop <nod>           Stoppa en nod snyggt (SIGTERM), t.ex. ./lab.sh stop mongo-node-2
  kill <nod>           Döda en nod hårt (SIGKILL, simulerar krasch)
  start <nod>          Starta en stoppad nod igen
  resync-test [nod] [kill]
                       Automatiskt test: seed -> stoppa nod -> skriv data medan den är nere -> starta den
                       -> verifiera att den synkat ikapp. Default nod: mongo-node-1, "kill" = hård krasch.
                       OBS: droppar och skriver om databasen labdb.
  dump [db]            mongodump av en databas (default labdb) till dumps/<db>_<version>_<tid>.archive.gz
                       (+ .json med antal dokument och index). Ändrar inget i klustret.
  restore [fil]        mongorestore av en dump (default: den senaste) in i det körande klustret (--drop:
                       ersätter databasen), sen jämförs antal dokument + index mot dumpen och testdatan verifieras.
  migrate <version> [db] [--yes|--dry-run]
                       Uppgradera via dump/restore i stället för rolling upgrade (kan hoppa över major-versioner,
                       t.ex. 5.0 -> 8.0): dump -> RIV klustret inkl. data -> starta nytt med <version> -> restore ->
                       verifiera. --dry-run tar bara dumpen och visar vad som skulle hända.
  shell [nod]          Öppna mongosh i en nod (default mongo-node-1)
  down                 Ta bort containrar och nätverk (behåller data)
  purge                Ta bort allt inklusive data
USAGE
  exit 1
}

is_node() { [[ "${1:-}" =~ ^mongo-node-[0-9]+$ ]]; }

# Nod med högst priority i replica setet = föredragen primary (frågar första nod som svarar).
current_preferred() {
  local n
  for n in mongo-node-1 mongo-node-2 mongo-node-3; do
    docker exec "$n" mongosh --quiet --eval 'print(rs.conf().members.reduce(function (a, b) { return b.priority > a.priority ? b : a; }).host.split(":")[0])' 2>/dev/null && return 0
  done
  return 1
}

die() { echo "$*" >&2; exit 1; }

DUMP_DIR="dumps"

# Replica set-anslutning som följer primary (används inifrån en container på docker-nätverket).
rs_uri() { echo "mongodb://mongo-node-1:27017,mongo-node-2:27017,mongo-node-3:27017/?replicaSet=rs0&serverSelectionTimeoutMS=30000"; }

# Första nod som kör.
running_node() { docker ps --filter 'name=^mongo-node-[0-9]+$' --filter status=running --format '{{.Names}}' | sort | head -1; }

# JSON med serverversion, antal dokument och indexnamn per collection: db_info <container> <db> [uri]
db_info() {
  docker exec "$1" mongosh --quiet "${3:-$(rs_uri)}" --eval "
    var d = db.getSiblingDB('$2');
    var names = d.getCollectionNames().filter(function (n) { return n.indexOf('system.') !== 0; }).sort();
    var counts = {}, indexes = {};
    names.forEach(function (n) {
      counts[n] = d.getCollection(n).countDocuments({});
      indexes[n] = d.getCollection(n).getIndexes().map(function (i) { return i.name; }).sort();
    });
    print(JSON.stringify({ version: db.version(), db: '$2', counts: counts, indexes: indexes }));"
}

# json_get <json> <python-uttryck över variabeln j>, t.ex. json_get "$info" 'j["version"]'
json_get() { python3 -c 'import json,sys; j=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" <<<"$1"; }

do_dump() {
  local db="${1:-labdb}" node info ver total file
  node="$(running_node)"; [ -n "$node" ] || die "Inget kluster kör. Starta det med ./lab.sh up"
  info="$(db_info "$node" "$db")" || die "Kunde inte läsa databasen $db (är klustret friskt? ./lab.sh status)"
  total="$(json_get "$info" 'sum(j["counts"].values())')"
  [ "$total" -gt 0 ] || die "Databasen '$db' är tom eller finns inte - inget att dumpa. (Fyll den med ./lab.sh seed)"
  ver="$(json_get "$info" 'j["version"]')"
  mkdir -p "$DUMP_DIR"
  file="$DUMP_DIR/${db}_${ver}_$(date +%Y%m%d-%H%M%S).archive.gz"
  echo "Dumpar '$db' från $node (MongoDB $ver): $(json_get "$info" 'j["counts"]')"
  # --archive utan filnamn skriver till stdout -> hamnar direkt i en fil på värden, kvar även efter purge.
  if ! docker exec "$node" mongodump --uri="$(rs_uri)" --db "$db" --archive --gzip > "$file" 2> "$file.log"; then
    cat "$file.log" >&2; rm -f "$file" "$file.log"; die "mongodump misslyckades"
  fi
  gzip -t "$file" || die "Dumpfilen är trasig: $file"
  echo "$info" > "${file%.archive.gz}.json"
  tail -1 "$file.log"; rm -f "$file.log"
  echo "Dump klar: $file ($(du -h "$file" | cut -f1))"
  DUMP_FILE="$file"
}

do_restore() {
  local file="${1:-}" node side info_src info_dst db n
  [ -n "$file" ] || file="$(ls -1t "$DUMP_DIR"/*.archive.gz 2>/dev/null | head -1 || true)"
  [ -n "$file" ] && [ -f "$file" ] || die "Ingen dump hittades (kör ./lab.sh dump först, eller ange fil)"
  side="${file%.archive.gz}.json"
  [ -f "$side" ] || die "Saknar $side (skapas av ./lab.sh dump) - behövs för att jämföra efter restore"
  node="$(running_node)"; [ -n "$node" ] || die "Inget kluster kör. Starta ett med ./lab.sh up <version>"
  info_src="$(cat "$side")"; db="$(json_get "$info_src" 'j["db"]')"
  echo "Återställer $file (dumpad från MongoDB $(json_get "$info_src" 'j["version"]')) till klustret via $node ..."
  # -i: mongorestore läser arkivet från stdin. --drop ersätter befintliga collections. majority = replikerat innan klart.
  local out
  if ! out="$(docker exec -i "$node" mongorestore --uri="$(rs_uri)" --archive --gzip --drop --writeConcern=majority < "$file" 2>&1)"; then
    echo "$out" >&2; die "mongorestore misslyckades"
  fi
  # Visa sammanfattningen och ev. varningar (t.ex. att mongorestore anser cross-version restore vara "unsupported").
  grep -E 'restored successfully|failed to restore|WARNING' <<<"$out" | sed 's/^[0-9T:.+-]*\t//' || true
  info_dst="$(db_info "$node" "$db")"
  if python3 - "$info_src" "$info_dst" <<'PYCMP'
import json, sys
s, d = json.loads(sys.argv[1]), json.loads(sys.argv[2])
ok = True
for k in ("counts", "indexes"):
    if s[k] != d[k]:
        ok = False
        print("FEL: %s skiljer sig\n  dump:    %s\n  klustret: %s" % (k, s[k], d[k]))
if ok:
    print("OK: samma antal dokument och samma index som i dumpen: %s" % d["counts"])
    print("    (dumpad från %s, återställd på %s)" % (s["version"], d["version"]))
sys.exit(0 if ok else 1)
PYCMP
  then :; else die "Återställningen stämmer inte med dumpen - se ovan"; fi
  # Djupkoll av seed-data (fält för fält + index), bara när databasen är labdb och ser ut som seed-data.
  n="$(json_get "$info_dst" 'j["counts"].get("users", "")')"
  if [ "$db" = labdb ] && [ -n "$n" ]; then
    echo "Verifierar testdatan ($n dokument per collection) på alla noder ..."
    ansible-playbook verify.yml -e "seed_docs_per_collection=$n"
  fi
}

do_migrate() {
  local target="" db=labdb yes=0 dry=0 arg src_ver dumpfile
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) yes=1 ;;
      --dry-run) dry=1 ;;
      -*) die "Okänd flagga: $arg" ;;
      *) if [ -z "$target" ]; then target="$arg"; else db="$arg"; fi ;;
    esac
  done
  [[ "$target" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "Ange målversion, t.ex. ./lab.sh migrate 8.0"
  local step_no=0
  step() { step_no=$((step_no + 1)); printf '\n\033[1m===== %s/5  %s\033[0m\n' "$step_no" "$*"; }

  step "Dumpa '$db' från det körande klustret"
  do_dump "$db"
  dumpfile="$DUMP_FILE"
  src_ver="$(json_get "$(cat "${dumpfile%.archive.gz}.json")" 'j["version"]')"

  echo
  echo "Nästa steg RIVER klustret inklusive ALL data i det (alla databaser, ${src_ver}) och startar ett nytt med mongo:$target."
  echo "Dumpen ligger kvar: $dumpfile"
  if [ "$dry" = 1 ]; then
    echo "[--dry-run] Skulle köra: ansible-playbook down.yml -e purge=true"
    echo "[--dry-run] Skulle köra: ansible-playbook up.yml -e mongodb_initial_version=$target"
    echo "[--dry-run] Skulle köra: restore $dumpfile  (+ jämförelse och verify)"
    echo "Ingenting ändrades i klustret."; return 0
  fi
  if [ "$yes" != 1 ]; then
    [ -t 0 ] || die "Kräver bekräftelse: kör i en terminal eller lägg till --yes"
    read -r -p "Fortsätta? Skriv 'ja': " reply
    [ "$reply" = ja ] || die "Avbrutet. Klustret är orört, dumpen finns kvar."
  fi

  step "Riv klustret inklusive data (containrar, nätverk och volymer)"
  ansible-playbook down.yml -e purge=true

  step "Starta nytt kluster med mongo:$target"
  ansible-playbook up.yml -e "mongodb_initial_version=$target"

  step "Återställ dumpen (mongorestore med verktygen från mongo:$target)"
  do_restore "$dumpfile"

  step "Klart - läget i klustret"
  ansible-playbook status.yml
  printf '\n\033[1mMIGRATE OK:\033[0m %s -> %s via dump/restore. Dumpen finns kvar: %s\n' "$src_ver" "$target" "$dumpfile"
}

resync_test() {
  local node="${1:-mongo-node-1}" how="${2:-stop}" preferred
  is_node "$node" || { echo "Ogiltig nod: $node (t.ex. mongo-node-2)" >&2; exit 1; }
  [[ "$how" == stop || "$how" == kill ]] || { echo "Andra argumentet är 'kill' eller utelämnas" >&2; exit 1; }
  preferred="$(current_preferred)" || { echo "Inget kluster svarar. Starta det med ./lab.sh up" >&2; exit 1; }
  local step_no=0
  step() { step_no=$((step_no + 1)); printf '\n\033[1m===== %s/8  %s\033[0m\n' "$step_no" "$*"; }

  step "Baslinje: skriv 30 dokument per collection (databasen droppas först) och verifiera alla noder"
  ansible-playbook seed.yml -e reset=true
  ansible-playbook verify.yml

  step "${how^^} $node"
  if [ "$how" = kill ]; then docker kill "$node"; else docker stop -t 60 "$node"; fi

  step "Skriv data MEDAN $node är nere: 40 dokument per collection (10 nya, en del orders skrivs om)"
  ansible-playbook seed.yml -e seed_docs_per_collection=40

  step "Verifiera noderna som kör (ska ha 40 dokument; $node visas som NERE)"
  ansible-playbook verify.yml -e seed_docs_per_collection=40

  step "Starta $node igen"
  docker start "$node"

  step "Vänta tills föredragen primary ($preferred) är primary igen"
  ansible-playbook primary.yml -e "mongo_preferred_primary=$preferred"

  step "Verifiera att $node synkat ikapp - ALLA 3 noder ska nu ha exakt samma 40 dokument"
  ansible-playbook verify.yml -e seed_docs_per_collection=40

  step "Klart - läget i klustret"
  ansible-playbook status.yml
  printf '\n\033[1mRESYNC-TEST OK:\033[0m %s missade skrivningar medan den var nere och hämtade ikapp allt efteråt.\n' "$node"
}

cmd="${1:-}"; [ -n "$cmd" ] && shift || usage
case "$cmd" in
  up)      if [ -n "${1:-}" ]; then exec ansible-playbook up.yml -e "mongodb_initial_version=$1"; else exec ansible-playbook up.yml; fi ;;
  upgrade) [ -n "${1:-}" ] || { echo "Målversion saknas, t.ex. ./lab.sh upgrade 7.0" >&2; usage; }
           v="$1"; shift; exec ansible-playbook upgrade.yml -e "target_version=$v" "$@" ;;
  status)  exec ansible-playbook status.yml ;;
  primary) node="${1:-mongo-node-1}"; is_node "$node" || { echo "Ogiltig nod: $node (t.ex. mongo-node-2)" >&2; exit 1; }
           exec ansible-playbook primary.yml -e "mongo_preferred_primary=$node" ;;
  seed)    if [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+$ ]]; then n="$1"; shift; exec ansible-playbook seed.yml -e "seed_docs_per_collection=$n" "$@"; else exec ansible-playbook seed.yml "$@"; fi ;;
  verify)  if [ -n "${1:-}" ] && [[ "$1" =~ ^[0-9]+$ ]]; then n="$1"; shift; exec ansible-playbook verify.yml -e "seed_docs_per_collection=$n" "$@"; else exec ansible-playbook verify.yml "$@"; fi ;;
  stop|kill|start)
           is_node "${1:-}" || { echo "Ange nod, t.ex. ./lab.sh $cmd mongo-node-2" >&2; exit 1; }
           # docker stop ger mongod SIGTERM och tid att stänga ner rent (samma 60 s som i labbet)
           case "$cmd" in stop) docker stop -t 60 "$1" ;; kill) docker kill "$1" ;; start) docker start "$1" ;; esac
           echo "Klart. Kolla läget med: ./lab.sh status" ;;
  resync-test) resync_test "$@" ;;
  dump)    do_dump "$@" ;;
  restore) do_restore "$@" ;;
  migrate) do_migrate "$@" ;;
  shell)   exec docker exec -it "${1:-mongo-node-1}" mongosh ;;
  down)    exec ansible-playbook down.yml ;;
  purge)   exec ansible-playbook down.yml -e purge=true ;;
  *)       usage ;;
esac
