// Delas av seed.js och verify.js: genererar deterministisk testdata, så verify kan räkna ut exakt
// vad som SKA ligga i databasen utan att något behöver sparas någonstans.
// Skriven i ES5 (var, function, forEach) så den kör i både mongosh och gamla mongo-shellen (MongoDB 4.0).
function pad4(i) { var s = String(i); while (s.length < 4) { s = '0' + s; } return s; }

function gen(coll, n) {
  var docs = [];
  for (var i = 1; i <= n; i++) {
    var created = new Date(Date.UTC(2024, 0, 1) + i * 86400000);
    if (coll === 'users') {
      docs.push({ _id: i, name: 'user-' + i, email: 'user' + i + '@lab.test', age: 20 + (i % 40), createdAt: created });
    } else if (coll === 'products') {
      docs.push({ _id: i, sku: 'SKU-' + pad4(i), name: 'product-' + i, priceCents: 500 + i * 25, stock: 100 - (i % 50) });
    } else if (coll === 'orders') {
      docs.push({ _id: i, userId: ((i * 7) % n) + 1, productId: ((i * 11) % n) + 1, qty: 1 + (i % 5), createdAt: created });
    } else {
      throw new Error('okänd collection: ' + coll);
    }
  }
  return docs;
}

// Index som seed skapar och verify kontrollerar (namn blir email_1, sku_1, userId_1).
var INDEX_SPECS = {
  users: [{ key: { email: 1 }, opts: { unique: true } }],
  products: [{ key: { sku: 1 }, opts: { unique: true } }],
  orders: [{ key: { userId: 1 }, opts: {} }],
};
function indexName(key) { return Object.keys(key).map(function (k) { return k + '_' + key[k]; }).join('_'); }

// Antal dokument via aggregate: fungerar likadant i alla shell-versioner (count() ger varning i mongosh).
function countDocs(coll) {
  var r = coll.aggregate([{ $count: 'n' }]).toArray();
  return r.length ? r[0].n : 0;
}

// JSON med sorterade nycklar, så jämförelsen inte beror på fältordning.
function canon(v) {
  return JSON.stringify(v, function (k, x) {
    if (x && typeof x === 'object' && !Array.isArray(x)) {
      return Object.keys(x).sort().reduce(function (o, key) { o[key] = x[key]; return o; }, {});
    }
    return x;
  });
}
