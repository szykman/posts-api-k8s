// Unit tests for src/auth.ts, run against the compiled output (`yarn test` builds first).
const test = require("node:test");
const assert = require("node:assert/strict");
const express = require("express");
const {loadApiToken, bearerToken, tokensMatch, requireToken, MIN_TOKEN_LENGTH} = require("../src/auth");

const TOKEN = "a".repeat(32);

test("loadApiToken fails closed when the token is missing or empty", () => {
    assert.throws(() => loadApiToken({}), /Missing required environment variable API_TOKEN/);
    assert.throws(() => loadApiToken({API_TOKEN: ""}), /Missing required environment variable API_TOKEN/);
});

test("loadApiToken rejects a token that is too short", () => {
    assert.throws(() => loadApiToken({API_TOKEN: "x".repeat(MIN_TOKEN_LENGTH - 1)}), /at least/);
    assert.equal(loadApiToken({API_TOKEN: "x".repeat(MIN_TOKEN_LENGTH)}), "x".repeat(MIN_TOKEN_LENGTH));
});

test("bearerToken accepts only the Bearer scheme, case-insensitively", () => {
    assert.equal(bearerToken("Bearer abc"), "abc");
    assert.equal(bearerToken("bearer abc"), "abc");
    assert.equal(bearerToken("BEARER abc"), "abc");
    assert.equal(bearerToken(undefined), undefined);
    assert.equal(bearerToken(""), undefined);
    assert.equal(bearerToken("Basic abc"), undefined);
    assert.equal(bearerToken("Bearer"), undefined);
    assert.equal(bearerToken("Bearer "), undefined);
    assert.equal(bearerToken("Bearer a b"), undefined);
    assert.equal(bearerToken("abc"), undefined);
});

test("tokensMatch compares values of different lengths without throwing", () => {
    assert.equal(tokensMatch(TOKEN, TOKEN), true);
    assert.equal(tokensMatch("b".repeat(32), TOKEN), false);
    assert.equal(tokensMatch("a", TOKEN), false);
    assert.equal(tokensMatch(TOKEN + "a", TOKEN), false);
});

// The middleware is exercised through a real HTTP server, so the headers and status codes are the ones a client sees.
async function withServer(run) {
    const app = express();
    app.get("/open", (req, res) => res.json({ok: true}));
    app.post("/protected", requireToken(TOKEN), (req, res) => res.status(201).json({ok: true}));
    const server = await new Promise((resolve) => {
        const s = app.listen(0, "127.0.0.1", () => resolve(s));
    });
    try {
        await run(`http://127.0.0.1:${server.address().port}`);
    } finally {
        await new Promise((resolve) => server.close(resolve));
    }
}

test("a protected route answers 401 without a token, with a wrong token and with another scheme", async () => {
    await withServer(async (base) => {
        for (const headers of [{}, {authorization: "Bearer wrong"}, {authorization: `Basic ${TOKEN}`}, {authorization: TOKEN}]) {
            const response = await fetch(`${base}/protected`, {method: "POST", headers});
            assert.equal(response.status, 401);
            assert.equal(response.headers.get("www-authenticate"), "Bearer");
            assert.deepEqual(await response.json(), {error: "Unauthorized"});
        }
    });
});

test("a protected route accepts the right token", async () => {
    await withServer(async (base) => {
        const response = await fetch(`${base}/protected`, {method: "POST", headers: {authorization: `Bearer ${TOKEN}`}});
        assert.equal(response.status, 201);
    });
});

test("routes without the middleware stay open", async () => {
    await withServer(async (base) => {
        const response = await fetch(`${base}/open`);
        assert.equal(response.status, 200);
    });
});
