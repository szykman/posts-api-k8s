# 1. Upgrade TypeORM from 0.2.38 to 0.3.31

Status: accepted

## Context

The application shipped with TypeORM 0.2.38 (October 2021). `yarn audit` reported 24 advisories for the
runtime dependencies (2 critical, 14 high, 7 moderate, 1 low). Four are in TypeORM itself and 20 in the
packages it pulls in (brace-expansion, js-yaml, minimatch, xml2js, sha.js, figlet). The four in TypeORM:

- CVE-2022-33171 (critical, fixed in 0.3.0): `findOne` receiving a user-controlled object instead of an id.
- CVE-2025-60542 (high, fixed in 0.3.26): `save`/`update` receiving a nested object where a scalar is
  expected, on MySQL-family drivers.
- Code injection through a template literal in `migration:generate` (moderate, fixed in 0.3.31).
- SQL injection in `UpdateQueryBuilder`/`SoftDeleteQueryBuilder` (moderate, fixed after 0.3.28).

The first two were analysed for reachability. The only `findOne` receives an integer validated by
`parseId`, and `save` only receives fields that `validatePostInput` has checked to be strings. The
application does not use the query builders at all, and `migration:generate` is a developer-time command,
not part of the runtime. That is a mitigation in the application, not a fix in the library, and any
future endpoint without validation would be exposed. The two moderate advisories were assessed from their
titles and version ranges only.

## Options

1. Keep 0.2.38 and document the unreachable advisories. No change, but scanners keep reporting a
   critical finding and the line is no longer where fixes land.
2. Upgrade to 0.3.31 (July 2026, the last release of the 0.3 line).
3. Upgrade to 1.x (the current `latest`; 1.0.0 is from May 2026).

## Decision

Upgrade to 0.3.31, measured before deciding on a throwaway copy of the repository.

- Cost: the 0.3 typings need TypeScript 5.4 or newer, so TypeScript 3.9 became 5.9 and `@types/node`
  9 became 22; the `mysql` driver became `mysql2`; the migration CLI needs a DataSource file. The
  application diff is small (see the commit), and the existing tests found the regressions that
  mattered.
- Result: `yarn audit` goes from 24 advisories to 0 for the runtime dependencies. 0.3.31 is the first
  release that clears all four TypeORM advisories (0.3.26 would still leave the `migration:generate`
  one). The 0.3.31 MySQL driver turns on `stringifyObjects`, which 0.2.38 does not.
- 1.x was probed and compiled and ran the same flows with no further change to our code, because the
  DataSource conversion is the real migration. It was not adopted because 1.1.2 was four days old at
  the time and the 0.3 line has years of use. Moving to 1.x is a cheap follow-up.

## Consequences

- The schema and the `migrations` table are unchanged. In a test database, 0.3 read and wrote data
  created by 0.2, and 0.2 then read what 0.3 wrote, so rolling the image back is safe while
  schema changes stay backward compatible. A rollback never reverts the schema.
- The migration command (`-d src/data-source.js`) lives in the chart but depends on the image: images
  before 0.2.0 do not ship that file. `helm rollback` restores the old chart revision together with the
  old image, so it is safe; a downgrade done with `helm upgrade --set image.tag=<older>` against the new
  chart would fail the migration hook. A stable command inside the image would remove the coupling.
- `mysql2` replaces `mysql`. The application only uses integer, varchar and text columns, and no load
  test has compared the two drivers.
- Node must satisfy the engines of the installed TypeORM; the image uses Node 22.
