// B-07 SQLite
// 3 ランタイムに組み込まれている SQLite（node:sqlite）へ一括 INSERT と SELECT を行う。
// node:sqlite を持たないランタイムでは unsupported として理由を残す（空欄にしない）。

import { now, report, reportUnsupported, envInt } from "./_report.mjs";

const ROWS = envInt("BENCH_SQLITE_ROWS", 100000);

let DatabaseSync;
try {
	({ DatabaseSync } = await import("node:sqlite"));
} catch (e) {
	reportUnsupported("B-07", `node:sqlite を import できない: ${e?.message ?? e}`);
	// 以降を実行しない
	globalThis.process?.exit?.(0);
	throw new Error("unsupported");
}

if (typeof DatabaseSync !== "function") {
	reportUnsupported("B-07", "node:sqlite に DatabaseSync が無い");
	globalThis.process?.exit?.(0);
}

// インメモリで測る（ディスク性能を B-05 と二重に測らないため）
const db = new DatabaseSync(":memory:");

const t0 = now();
db.exec(`
	CREATE TABLE items (
		id INTEGER PRIMARY KEY,
		name TEXT NOT NULL,
		city TEXT NOT NULL,
		score REAL NOT NULL
	);
	CREATE INDEX idx_items_city ON items(city);
`);
const t1 = now();

const insert = db.prepare("INSERT INTO items (id, name, city, score) VALUES (?, ?, ?, ?)");
const cities = ["東京", "大阪", "名古屋", "札幌", "福岡", "仙台", "広島", "那覇"];
db.exec("BEGIN");
for (let i = 0; i < ROWS; i++) {
	insert.run(i, "name" + i.toString(36), cities[i % cities.length], (i % 10000) / 100);
}
db.exec("COMMIT");
const t2 = now();

const selectAll = db.prepare("SELECT city, COUNT(*) AS n, AVG(score) AS avg FROM items GROUP BY city ORDER BY n DESC");
const grouped = selectAll.all();
const t3 = now();

const point = db.prepare("SELECT name, score FROM items WHERE id = ?");
let hit = 0;
for (let i = 0; i < 20000; i++) {
	const row = point.get((i * 7) % ROWS);
	if (row) hit++;
}
const t4 = now();

db.close();

report("B-07", t4 - t0, {
	rows: ROWS,
	createMs: Math.round((t1 - t0) * 1000) / 1000,
	insertMs: Math.round((t2 - t1) * 1000) / 1000,
	aggregateMs: Math.round((t3 - t2) * 1000) / 1000,
	pointSelectMs: Math.round((t4 - t3) * 1000) / 1000,
	groups: grouped.length,
	pointHits: hit,
});
