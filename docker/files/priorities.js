// Förutsätter PREFERRED (nodnamn) och PRIORITY (tal) före sig. Sätter PRIORITY på den föredragna noden och 1 på
// övriga. Körs mot primary (via replica set-URI). Gör ingenting om prioriteterna redan stämmer.
// ES5. Gamla mongo-shellen kastar inte fel vid misslyckad reconfig (returnerar ok:0), så resultatet kollas.
var cfg = rs.conf();
var changed = false;
var found = false;
cfg.members.forEach(function (m) {
  var isPreferred = m.host.split(':')[0] === PREFERRED;
  if (isPreferred) found = true;
  var want = isPreferred ? PRIORITY : 1;
  if (Number(m.priority) !== want) { m.priority = want; changed = true; }
});
if (!found) { throw new Error('Noden ' + PREFERRED + ' finns inte i replica setet'); }
if (changed) {
  var r = rs.reconfig(cfg);
  if (r && r.ok !== undefined && !r.ok) { throw new Error('rs.reconfig misslyckades: ' + JSON.stringify(r)); }
}
print(JSON.stringify({ changed: changed, priorities: cfg.members.map(function (m) { return m.host + '=' + m.priority; }) }));
