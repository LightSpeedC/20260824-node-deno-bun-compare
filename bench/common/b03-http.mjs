// B-03 HTTP スループット（共通版）
// 3 ランタイム共通の node:http だけで書いた最小サーバ。
// ランタイム固有 API 版（bench/native/）とは別項目として集計する。

import { createServer } from "node:http";
// Deno では Buffer がグローバルに無いため明示的に import する
import { Buffer } from "node:buffer";

const port = Number(globalThis.process?.env?.BENCH_PORT ?? 3000);

const body = "Hello";

const server = createServer((req, res) => {
	res.writeHead(200, {
		"content-type": "text/plain; charset=utf-8",
		"content-length": String(Buffer.byteLength(body)),
	});
	res.end(body);
});

server.listen(port, "127.0.0.1", () => {
	// ドライバはこの行を待ってから負荷をかける
	console.log(`READY node:http ${port}`);
});
