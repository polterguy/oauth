# OAuth for Magic

A minimal **OAuth 2.1 Authorization Server**, implemented (almost) entirely in Hyperlambda. It lets
any standards-compliant OAuth client — Claude, Cursor, the Claude API, … — connect to this cloudlet's
[MCP server](../mcp/README.md) through the normal browser flow: **discover, self-register, log in,
consent, and receive a token** — with no manually-pasted credentials.

The crucial design point: **the access token it issues is just a normal Magic JWT.** The MCP endpoint
already validates `Bearer <Magic JWT>` and enforces per-endpoint `[auth.ticket.verify]`, so OAuth adds
no new authorization layer — it's purely a *standards-compliant way to deliver a JWT*. Claude ends up
acting as the consenting user, with **that user's roles**.

- **Authorization endpoint:** `GET` / `POST /magic/modules/oauth/authorize`
- **Token endpoint:** `POST /magic/modules/oauth/token`
- **Registration endpoint (DCR):** `POST /magic/modules/oauth/register`
- **Metadata:** `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource`
- **Grants:** `authorization_code` (PKCE **S256**, mandatory) and `refresh_token`
- **Specs:** RFC 6749, 7591 (DCR), 7636 (PKCE), 8414 + 9728 (metadata), 8707 (resource)

## How it works

Everything below happens automatically once the client is pointed at the MCP URL:

1. **Discovery.** The client calls the MCP endpoint with no token → `401` + a `WWW-Authenticate` header
   pointing at `/.well-known/oauth-protected-resource`, which in turn names this cloudlet as its
   authorization server. The client then reads `/.well-known/oauth-authorization-server` for the
   endpoint URLs and supported PKCE methods.
2. **Registration.** The client self-registers (`POST /register`) with its `redirect_uris`; it gets back
   a generated `client_id`, stored in `oauth_clients`.
3. **Authorization + consent.** The client opens the user's browser at `/authorize` carrying a PKCE
   `code_challenge` and `state`. `authorize.get.hl` renders a login + consent page; on **Allow** its JS
   authenticates the user against this cloudlet, calls `authorize` (POST) to mint a single-use code, and
   redirects back to the client with `?code=…&state=…`.
4. **Token.** The client exchanges the code (+ its PKCE `code_verifier`) at `/token` over the back
   channel. After PKCE verification the code is burned and a JWT is minted carrying the user's username
   and roles, plus an opaque refresh token.
5. **Use.** The client calls MCP with `Authorization: Bearer <JWT>`. Refreshes happen silently via the
   `refresh_token` grant; no further consent is needed.

The user's identity and roles are snapshotted **at the moment of consent** (the one point a human is
present) and carried through the code → token → refresh chain.

## Files

| File | Role |
| --- | --- |
| `register.post.hl` | Dynamic Client Registration (RFC 7591). Unauthenticated; accepts any client metadata (`.arguments:*`). |
| `authorize.get.hl` | The consent + login page (returns `text/html`). Validates the client/redirect, then renders a page whose JS logs in and drives `authorize.post.hl`. |
| `authorize.post.hl` | Code issuance. Requires the consenting user's JWT; validates client + redirect, snapshots username + roles, writes a single-use PKCE-bound code to the cache (60 s), returns the redirect URL. |
| `token.post.hl` | The token endpoint. Two grants — `authorization_code` (PKCE-verified) and `refresh_token` (rotating) — both minting an access JWT + a fresh refresh token. |
| `magic.startup/magic.oauth.install-wellknown.hl` | On startup, copies the metadata code-behind into `/etc/www/.well-known/` if absent. Idempotent — a customised copy is left untouched. |
| `magic.startup/oauth-authorization-server.{html,hl}` | Code-behind serving the RFC 8414 metadata as JSON, with URLs derived from the request host. |
| `magic.startup/oauth-protected-resource.{html,hl}` | Code-behind serving the RFC 9728 metadata. |
| `magic.startup/ensure-database.hl` + `oauth.sqlite.sql` | Creates the module's database on first startup. |
| `magic.startup/db-migrations/` | Schema upgrades for already-installed databases. |

## Database

| Table | Holds |
| --- | --- |
| `oauth_clients` | Registered clients: `client_id`, `client_name`, `redirect_uris` (JSON), `created`. |
| `oauth_refresh_tokens` | Opaque refresh tokens bound to `username`, `roles` (JSON), `client_id`. |

Authorization codes are **not** stored in a table — they're short-lived (60 s) cache entries keyed
`oauth_code.<code>`, holding `{client_id, redirect_uri, code_challenge, username, roles}`.

## Security

- **PKCE S256 is mandatory.** `authorize` records the `code_challenge`; `token` recomputes
  `base64url(sha256(code_verifier))` and rejects a mismatch. A stolen code is useless without the
  verifier, which never leaves the client.
- **Authorization codes are single-use and 60-second.** Burned on first redemption; they only need to
  survive the immediate redirect → token hand-off.
- **Refresh tokens are opaque, not JWTs** — so they can never be replayed as access tokens — and are
  **rotated** on every use (the presented one is deleted, a new one issued).
- **Redirect URIs are validated** against the client's registered set on both `authorize` legs; an
  unknown client or redirect gets a `400` error page, **never a redirect** (no open redirector).
- **The token is only as privileged as the consenting user.** Consenting `root` yields a `root` token.
  To cap the blast radius regardless of who consents, mint a dedicated limited role in
  `authorize.post.hl` instead of copying the user's roles, or map OAuth scopes to a role subset.

## Setup

This module is self-installing — on startup it creates its database and drops the metadata into
`/etc/www/.well-known/`. Two things outside this folder are required:

1. **Backend `.well-known` fix (required, compiled).** Magic's static handler hides dot-folders, so
   `/.well-known/*` would `404`. `IsLegalFileRequest` in `magic.endpoint`'s `Utilities.cs` must allow
   the `.well-known` segment. This is a C# change — the cloudlet must run a build that includes it.
2. **MCP discovery gate.** `mcp.post.hl` gained an `auth.ticket.get` check at the top: an
   unauthenticated request now returns `401` + `WWW-Authenticate` (pointing at the protected-resource
   metadata) instead of serving anonymously. **This means the MCP endpoint now requires a token** —
   that 401 is what makes a client begin the OAuth flow. Remove that block to go back to anonymous.

> **Scheme note.** The metadata and the `401` hardcode `https://` + `request.host`. Behind a TLS
> proxy (CloudFlare, etc.) the backend sees the internal `http` hop, and `request.scheme` would
> wrongly advertise `http://`. CloudFlare passes the real `Host` through, so `request.host` is
> correct; only the scheme is forced. (Locally the metadata reads `https://localhost`, which is
> harmless — the real flow needs a public host anyway.)

## Testing

```bash
HOST=https://your-cloudlet
JWT=...   # a Magic JWT for the consenting user (the browser supplies this in the real flow)

# 1) Register a client
CID=$(curl -s -X POST $HOST/magic/modules/oauth/register -H 'Content-Type: application/json' \
  -d '{"client_name":"Claude","redirect_uris":["https://claude.ai/cb"]}' | jq -r .client_id)

# 2) Authorize (the browser does this after consent; challenge here is the RFC 7636 test vector)
CODE=$(curl -s -X POST $HOST/magic/modules/oauth/authorize -H "Authorization: Bearer $JWT" \
  --data-urlencode "client_id=$CID" --data-urlencode "redirect_uri=https://claude.ai/cb" \
  --data-urlencode "code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" \
  --data-urlencode "state=xyz" | jq -r '.redirect | capture("code=(?<c>[^&]+)").c')

# 3) Exchange the code (verifier matching the vector above)
curl -s -X POST $HOST/magic/modules/oauth/token \
  -d "grant_type=authorization_code&code=$CODE&client_id=$CID&redirect_uri=https://claude.ai/cb&code_verifier=dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" | jq .

# 4) Refresh
curl -s -X POST $HOST/magic/modules/oauth/token \
  -d "grant_type=refresh_token&refresh_token=THE_REFRESH_TOKEN&client_id=$CID" | jq .
```

## Connecting Claude

Add the cloudlet's MCP URL as a custom connector — no token, no JSON config:

```
https://your-cloudlet/magic/modules/mcp/mcp
```

Claude hits the `401`, walks the discovery + registration + consent flow above, and is connected.
Before adding it, sanity-check that `curl $HOST/.well-known/oauth-authorization-server` reports your
**real domain with `https://`**.

## Known limitations (v1)

- The access token inherits the user's **roles only** — not custom JWT claims (a deliberate choice).
- Refresh tokens have no hard expiry; rotation is the only invalidation (besides deleting the row).
- No revocation, introspection, or `scopes`-to-role mapping yet — `scope` is accepted and echoed but
  not enforced; every token currently carries the user's full role set.
- The browser/JS half of the consent page is verified by hand, not by an automated test.
- Consent requires a username/password login on the page (the cloudlet is a different origin from the
  dashboard, so an existing dashboard session can't be reused).
