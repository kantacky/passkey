import index from "./index.html";

const apiOrigin = process.env.API_ORIGIN ?? "http://localhost:8080";
const port = Number(process.env.PORT ?? 3000);

const server = Bun.serve({
  port,
  development: {
    hmr: true,
    console: true,
  },
  routes: {
    "/api/*": async (request) => {
      const url = new URL(request.url);
      const target = new URL(url.pathname + url.search, apiOrigin);
      const headers = new Headers(request.headers);
      headers.delete("host");
      headers.delete("x-forwarded-for");
      headers.delete("x-real-ip");
      headers.delete("x-client-ip");
      headers.set("x-client-ip", "127.0.0.1");
      return fetch(target, {
        method: request.method,
        headers,
        body:
          request.method === "GET" || request.method === "HEAD"
            ? undefined
            : await request.arrayBuffer(),
        redirect: "manual",
      });
    },
    "/*": index,
  },
});

console.log(`web dev server: http://localhost:${server.port}`);
console.log(`API proxy: ${apiOrigin}`);
