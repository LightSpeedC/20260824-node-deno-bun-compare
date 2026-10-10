// B-03 HTTP スループット（Bun 固有 API 版）
// Bun.serve を使う。共通版（node:http）とは別項目として集計する。

const port = Number(globalThis.process?.env?.BENCH_PORT ?? 3000);
const body = "Hello";

Bun.serve({
	port,
	hostname: "127.0.0.1",
	fetch: () =>
		new Response(body, {
			headers: { "content-type": "text/plain; charset=utf-8" },
		}),
});

console.log(`READY Bun.serve ${port}`);
