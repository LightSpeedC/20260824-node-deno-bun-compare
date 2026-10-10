// P3 npm 互換性チェック
// 性質の異なる npm パッケージを 1 つずつ import し、成功／失敗を記録する。
// 落ちたものは理由を残す（互換性比較では失敗そのものが結果になる）。

const TARGETS = [
	{ name: "zod", kind: "純 JS ライブラリ", spec: "zod", check: (m) => typeof (m.z ?? m.default ?? m) === "object" || typeof m.string === "function" },
	{ name: "dayjs", kind: "純 JS ライブラリ", spec: "dayjs", check: (m) => typeof (m.default ?? m) === "function" },
	{ name: "express", kind: "HTTP フレームワーク", spec: "express", check: (m) => typeof (m.default ?? m) === "function" },
	{ name: "pg", kind: "DB ドライバ", spec: "pg", check: (m) => typeof (m.Client ?? m.default?.Client) === "function" },
	{ name: "esbuild", kind: "ビルドツール（ネイティブバイナリ同梱）", spec: "esbuild", check: (m) => typeof (m.transformSync ?? m.default?.transformSync) === "function" },
	{ name: "prettier", kind: "CLI ツール（bin エントリあり）", spec: "prettier", check: (m) => typeof (m.format ?? m.default?.format) === "function" },
	{ name: "sharp", kind: "ネイティブアドオン（プリビルド配布）", spec: "sharp", check: (m) => typeof (m.default ?? m) === "function" },
	{ name: "better-sqlite3", kind: "ネイティブアドオン（要ビルド）", spec: "better-sqlite3", check: (m) => typeof (m.default ?? m) === "function" },
];

const results = [];

for (const t of TARGETS) {
	const t0 = performance.now();
	let ok = false;
	let reason = "";
	let usable = false;
	try {
		const mod = await import(t.spec);
		ok = true;
		try {
			usable = Boolean(t.check(mod));
			if (!usable) {
				reason = "import は成功したが期待するエクスポートが無い";
			}
		} catch (e) {
			usable = false;
			reason = "エクスポート確認で例外: " + (e?.message ?? String(e));
		}
	} catch (e) {
		ok = false;
		reason = (e?.code ? `[${e.code}] ` : "") + (e?.message ?? String(e));
	}
	const ms = Math.round((performance.now() - t0) * 1000) / 1000;
	// 長いスタックトレースは 1 行に潰す
	reason = String(reason).split("\n")[0].slice(0, 300);
	results.push({ name: t.name, kind: t.kind, imported: ok, usable, ms, reason });
}

console.log("COMPAT " + JSON.stringify({ results }));
