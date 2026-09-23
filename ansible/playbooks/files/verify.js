// Förutsätter CFG = {db, n, collections} och testdata.js före sig. Körs mot EN nod (direktanslutning).
// Jämför varje dokument fält för fält mot det seed genererar, och kontrollerar index.
// ES5 + isMaster (finns i alla versioner; db.hello() finns bara i 4.4.2+).
var d = db.getSiblingDB(CFG.db);
var result = { isPrimary: db.isMaster().ismaster === true, ok: true, problems: [], counts: {} };
CFG.collections.forEach(function (c) {
  var expected = gen(c, CFG.n);
  var got = d.getCollection(c).find().sort({ _id: 1 }).toArray();
  result.counts[c] = got.length;
  var gotIds = got.map(function (x) { return x._id; });
  var missing = expected.filter(function (e) { return gotIds.indexOf(e._id) < 0; }).length;
  var extra = got.length - (expected.length - missing);
  var changed = expected.filter(function (e) {
    var g = got.filter(function (x) { return x._id === e._id; })[0];
    return g && canon(e) !== canon(g);
  }).length;
  if (missing) result.problems.push(c + ': ' + missing + ' av de ' + CFG.n + ' förväntade dokumenten saknas (seedade du ett annat antal? kör ./lab.sh verify <antal>)');
  if (extra) result.problems.push(c + ': ' + extra + ' fler dokument än de ' + CFG.n + ' som verify förväntar sig (seedade du ett annat antal? kör ./lab.sh verify <antal>)');
  if (changed) result.problems.push(c + ': ' + changed + ' dokument har fel innehåll');
  var have = d.getCollection(c).getIndexes().map(function (i) { return i.name; });
  (INDEX_SPECS[c] || []).forEach(function (s) {
    if (have.indexOf(indexName(s.key)) < 0) result.problems.push(c + ': index ' + indexName(s.key) + ' saknas');
  });
});
result.ok = result.problems.length === 0;
print(JSON.stringify(result));
