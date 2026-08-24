// B-03 HTTP スループット（Deno 固有 API 版）
// Deno.serve を使う。共通版（node:http）とは別項目として集計する。

const port = Number(Deno.env.get("BENCH_PORT") ?? "3000");
const body = "Hello";

Deno.serve(
	{
		port,
		hostname: "127.0.0.1",
		onListen: () => {
			console.log(`READY Deno.serve ${port}`);
		},
	},
	() =>
		new Response(body, {
			headers: { "content-type": "text/plain; charset=utf-8" },
		}),
);
