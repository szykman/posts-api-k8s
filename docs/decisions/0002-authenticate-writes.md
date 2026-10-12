# 2. Authenticate writes with a Bearer token

Status: accepted

## Context

`POST /posts` created rows for anyone who could reach the ingress. Nobody told us who the producers are,
so the safe assumption is that the API can be reached from the internet, where scanners and bots find open
ports and can fill the database with junk (storage, cost, and a public listing of whatever they post).
Reading posts is the purpose of the API and does not change anything.

## Options

1. No authentication, documented as a limitation. Acceptable only on a private network we control.
2. Network restriction only (a NetworkPolicy, a private ingress, an allow-list). Cheap, but anything
   inside the allowed range can still write, and it says nothing about who is calling.
3. One shared Bearer token for writes, stored in a Secret.
4. Per-client credentials: OAuth 2 / JWT from an identity provider, or mutual TLS.
5. Authentication in a gateway in front of the API instead of in the application.

## Decision

Option 3, fail closed, for writes only.

- `POST /posts` requires `Authorization: Bearer <API_TOKEN>`. `GET /posts`, `GET /posts/:id`, `/health` and
  `/ready` stay open (the Kubernetes probes carry no credentials).
- The application refuses to start without `API_TOKEN` or with fewer than 16 characters. There is no switch
  to turn the check off: a switch that can be forgotten in production is the failure this avoids.
- The token is compared in constant time (both values are hashed, then `timingSafeEqual`), and a missing,
  malformed or wrong token all get the same `401` with `WWW-Authenticate: Bearer`. Authentication runs
  before the body is parsed.
- The token comes from the Secret `posts-api-token` (key `API_TOKEN`), created out of band like the
  database credentials: `bootstrap.sh up` generates it with `openssl rand -hex 32`. It is not in Git
  or in the image. The chart puts the Secret's hash in a pod annotation, so after rotating the token a
  `helm upgrade` restarts the pods and they pick up the new one.

Option 3 was chosen because it is proportionate: a small amount of code, no new component, and it stops
the case we are worried about. Options 4 and 5 are what to move to when the producers are known, see below.

## Consequences

- **Without TLS the token travels in clear text.** Anyone on the path can read it. This decision is
  only complete together with TLS at the ingress, which is the next step; until then the ingress must not be
  exposed beyond a network we trust. Authentication and transport encryption are different layers.
- One shared token cannot tell producers apart, and revoking one producer means rotating for all of them.
  If several parties write, move to per-client credentials (option 4) or authenticate at a gateway (5).
- Rotation is: update the Secret, then `helm upgrade`. The rolling update keeps the API available; clients
  must switch to the new token at the same time, because there is only one valid token at any moment.
- Reads are public on purpose. If the data is not meant to be public, that is a different decision.
- A caller who already holds the token can still send many requests: there is no rate limit yet. The token
  has 256 bits, so guessing it is not realistic, but a leaked token is unlimited until rotated.
- The check is exercised by 7 unit tests (token loading, header parsing, the middleware through a real
  HTTP server) and by the smoke test (a POST without a token and with a wrong one answer 401, the right
  token gives 201). The API was also run against a real MariaDB: 401, 401, 201, and exit code 1 at start
  without a token.
