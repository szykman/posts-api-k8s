// Unit tests for src/validation.ts. They run against the compiled output (run `yarn build` first,
// or use `yarn test`, which does both). No test framework: Node's built-in runner is enough.
const test = require("node:test");
const assert = require("node:assert/strict");
const {validatePostInput, parseId} = require("../src/validation");

const rejected = (body) => validatePostInput(body).errors;

test("accepts a minimal post", () => {
    const result = validatePostInput({title: "hello", text: "world"});
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.value, {title: "hello", text: "world"});
});

test("accepts categories and keeps only their name", () => {
    const result = validatePostInput({title: "t", text: "x", categories: [{name: "k8s"}, {name: "helm"}]});
    assert.deepEqual(result.errors, []);
    assert.deepEqual(result.value.categories, [{name: "k8s"}, {name: "helm"}]);
});

test("rejects a client-supplied id (mass assignment)", () => {
    assert.deepEqual(rejected({id: 1, title: "t", text: "x"}), ['unknown field "id"']);
});

test("rejects unknown fields, including __proto__", () => {
    assert.ok(rejected({title: "t", text: "x", admin: true}).length > 0);
    assert.ok(rejected(JSON.parse('{"title":"t","text":"x","__proto__":{"polluted":true}}')).length > 0);
    assert.equal({}.polluted, undefined);
});

test("rejects bodies that are not a JSON object", () => {
    for (const body of [null, undefined, [], "text", 42, true]) {
        assert.deepEqual(rejected(body), ["body must be a JSON object"]);
    }
});

test("requires title and text to be non-empty strings", () => {
    assert.ok(rejected({text: "x"}).includes("title must be a non-empty string"));
    assert.ok(rejected({title: "   ", text: "x"}).includes("title must be a non-empty string"));
    assert.ok(rejected({title: 5, text: "x"}).includes("title must be a non-empty string"));
    assert.ok(rejected({title: "t"}).includes("text must be a non-empty string"));
    assert.ok(rejected({title: "t", text: {}}).includes("text must be a non-empty string"));
});

test("enforces the column limits", () => {
    assert.deepEqual(rejected({title: "a".repeat(255), text: "x"}), []);
    assert.equal(rejected({title: "a".repeat(256), text: "x"}).length, 1);
    assert.deepEqual(rejected({title: "t", text: "a".repeat(65535)}), []);
    assert.equal(rejected({title: "t", text: "a".repeat(65536)}).length, 1);
});

test("measures text in bytes, not characters", () => {
    // 30000 characters of 3 bytes each = 90000 bytes: fits in characters, not in a TEXT column
    assert.equal(rejected({title: "t", text: "\u20ac".repeat(30000)}).length, 1);
});

test("validates categories", () => {
    assert.ok(rejected({title: "t", text: "x", categories: "k8s"}).includes("categories must be an array"));
    assert.ok(rejected({title: "t", text: "x", categories: [{id: 3, name: "k"}]}).some((e) => e.includes("unknown field")));
    assert.ok(rejected({title: "t", text: "x", categories: [{}]}).some((e) => e.includes("name must be")));
    assert.ok(rejected({title: "t", text: "x", categories: ["k8s"]}).some((e) => e.includes("must be an object")));
    const eleven = Array.from({length: 11}, (_, i) => ({name: "c" + i}));
    assert.ok(rejected({title: "t", text: "x", categories: eleven}).some((e) => e.includes("at most 10")));
});

test("caps the number of reported errors and the length of echoed keys", () => {
    const body = {};
    for (let i = 0; i < 100; i++) body["k" + i] = i;
    assert.equal(rejected(body).length, 20);
    const long = rejected({["x".repeat(500)]: 1, title: "t", text: "x"})[0];
    assert.ok(long.length < 100);
});

test("parseId accepts only plain positive 32-bit integers", () => {
    assert.equal(parseId("1"), 1);
    assert.equal(parseId("2147483647"), 2147483647);
    for (const raw of ["0", "-1", "1abc", "1.5", "01", "", " 1", "1 ", "2147483648", "99999999999999999999", "abc", "1e3", "0x10"]) {
        assert.equal(parseId(raw), undefined, `"${raw}" must be rejected`);
    }
});
