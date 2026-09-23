// Förutsätter CFG = {db, n, collections, reset} och testdata.js före sig. Idempotent (upsert på _id).
// Skrivs med w:majority + j:true, dvs. bekräftat på minst 2 av 3 noder innan kommandot returnerar.
// ES5 - kör i både mongosh och gamla mongo-shellen (4.0).
var d = db.getSiblingDB(CFG.db);
var wc = { w: 'majority', j: true, wtimeout: 20000 };
if (CFG.reset) { d.dropDatabase(); }
var summary = {};
CFG.collections.forEach(function (c) {
  var ops = gen(c, CFG.n).map(function (doc) {
    return { replaceOne: { filter: { _id: doc._id }, replacement: doc, upsert: true } };
  });
  var r = d.getCollection(c).bulkWrite(ops, { ordered: true, writeConcern: wc });
  (INDEX_SPECS[c] || []).forEach(function (s) { d.getCollection(c).createIndex(s.key, s.opts); });
  summary[c] = { inserted: r.upsertedCount, updated: r.modifiedCount, total: countDocs(d.getCollection(c)) };
});
print(JSON.stringify(summary));
