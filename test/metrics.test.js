// Unit tests for src/metrics.ts, run against the compiled output (`yarn test` builds first).
const test = require("node:test");
const assert = require("node:assert/strict");
const express = require("express");
const {createMetrics, createMetricsServer} = require("../src/metrics");
const {requireToken} = require("../src/auth");

const TOKEN = "a".repeat(32);

function listen(server) {
    return new Promise((resolve) => {
        const s = server.listen(0, "127.0.0.1", () => resolve(s));
    });
}

function close(server) {
    return new Promise((resolve) => server.close(resolve));
}

// The value of one sample of a metric, or undefined when no such series exists. `text` is the Prometheus exposition
// format, `labels` the label pairs that must be present on the series (their order in the text does not matter).
function sample(text, name, labels = {}) {
    for (const line of text.split("\n")) {
        if (!line.startsWith(`${name}{`) && !line.startsWith(`${name} `)) {
            continue;
        }
        const open = line.indexOf("{");
        const present = open === -1 ? "" : line.slice(open + 1, line.lastIndexOf("}"));
        if (Object.entries(labels).every(([key, value]) => present.split(",").includes(`${key}="${value}"`))) {
            return Number(line.slice(line.lastIndexOf(" ") + 1));
        }
    }
    return undefined;
}

// A small app with the same three kinds of route as the real one (read, parameterised read, protected write)
// plus the probes, wrapped by the middleware under test.
async function withApp(run) {
    const metrics = createMetrics({defaultMetrics: false});
    const app = express();
    app.use(metrics.middleware);
    app.get("/health", (req, res) => res.json({status: "ok"}));
    app.get("/ready", (req, res) => res.json({status: "ok"}));
    app.get("/posts", (req, res) => res.json([]));
    app.get("/posts/:id", (req, res) => res.json({}));
    app.post("/posts", requireToken(TOKEN), (req, res) => res.status(201).json({}));
    const server = await listen(app);
    try {
        await run(`http://127.0.0.1:${server.address().port}`, metrics);
    } finally {
        await close(server);
    }
}

// The middleware records on "finish", which can land a moment after the client has the response.
async function settle() {
    await new Promise((resolve) => setTimeout(resolve, 20));
}

test("requests are counted by method, route pattern and status code", async () => {
    await withApp(async (base, metrics) => {
        await (await fetch(`${base}/posts`)).text();
        await (await fetch(`${base}/posts`)).text();
        await (await fetch(`${base}/posts`, {method: "POST", headers: {authorization: `Bearer ${TOKEN}`}})).text();
        await (await fetch(`${base}/posts`, {method: "POST"})).text();
        await settle();
        const text = await metrics.registry.metrics();
        assert.equal(sample(text, "http_requests_total", {method: "GET", route: "/posts", status_code: "200"}), 2);
        assert.equal(sample(text, "http_requests_total", {method: "POST", route: "/posts", status_code: "201"}), 1);
        assert.equal(sample(text, "http_requests_total", {method: "POST", route: "/posts", status_code: "401"}), 1);
    });
});

test("the route label is the pattern, so ids do not create one series each", async () => {
    await withApp(async (base, metrics) => {
        for (const id of ["1", "2", "3", "99999"]) {
            await (await fetch(`${base}/posts/${id}`)).text();
        }
        await settle();
        const text = await metrics.registry.metrics();
        assert.equal(sample(text, "http_requests_total", {route: "/posts/:id", status_code: "200"}), 4);
        assert.ok(!text.includes('route="/posts/1"'), "a raw URL must never become a label value");
    });
});

test("paths that match no route share one 'unmatched' series", async () => {
    await withApp(async (base, metrics) => {
        for (const path of ["/wp-admin", "/.env", "/a/b/c"]) {
            const response = await fetch(`${base}${path}`);
            assert.equal(response.status, 404);
            await response.text();
        }
        await settle();
        const text = await metrics.registry.metrics();
        assert.equal(sample(text, "http_requests_total", {route: "unmatched", status_code: "404"}), 3);
        assert.ok(!text.includes("wp-admin"), "a probed path must never become a label value");
    });
});

test("the probes are not counted", async () => {
    await withApp(async (base, metrics) => {
        await (await fetch(`${base}/health`)).text();
        await (await fetch(`${base}/ready`)).text();
        await settle();
        const text = await metrics.registry.metrics();
        assert.equal(sample(text, "http_requests_total"), undefined);
    });
});

test("the duration histogram records every counted request", async () => {
    await withApp(async (base, metrics) => {
        await (await fetch(`${base}/posts`)).text();
        await (await fetch(`${base}/posts`)).text();
        await settle();
        const text = await metrics.registry.metrics();
        const labels = {method: "GET", route: "/posts", status_code: "200"};
        assert.equal(sample(text, "http_request_duration_seconds_count", labels), 2);
        assert.equal(sample(text, "http_request_duration_seconds_bucket", {...labels, le: "+Inf"}), 2);
        assert.ok(sample(text, "http_request_duration_seconds_sum", labels) >= 0);
    });
});

test("the metrics server answers GET /metrics with the exposition format, and nothing else", async () => {
    const metrics = createMetrics();
    const server = await listen(createMetricsServer(metrics.registry));
    try {
        const base = `http://127.0.0.1:${server.address().port}`;

        const ok = await fetch(`${base}/metrics`);
        assert.equal(ok.status, 200);
        assert.match(ok.headers.get("content-type"), /^text\/plain/);
        const text = await ok.text();
        assert.match(text, /# TYPE http_requests_total counter/);
        assert.match(text, /# TYPE http_request_duration_seconds histogram/);
        assert.match(text, /process_cpu_user_seconds_total/, "the default process metrics are included");
        assert.match(text, /nodejs_eventloop_lag_seconds/, "the event loop lag is included");

        assert.equal((await fetch(`${base}/metrics?x=1`)).status, 200, "a query string does not change the route");
        for (const [path, method] of [["/", "GET"], ["/posts", "GET"], ["/metrics", "POST"], ["/metrics/", "GET"]]) {
            const response = await fetch(`${base}${path}`, {method});
            assert.equal(response.status, 404, `${method} ${path}`);
            await response.text();
        }
    } finally {
        await close(server);
    }
});

test("the API app has no /metrics route of its own", async () => {
    await withApp(async (base) => {
        const response = await fetch(`${base}/metrics`);
        assert.equal(response.status, 404);
        await response.text();
    });
});
