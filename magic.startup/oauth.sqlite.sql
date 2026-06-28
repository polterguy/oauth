/*
 * Database for the OAuth module.
 *
 * "oauth_clients"        - OAuth clients registered through Dynamic Client Registration (RFC 7591).
 * "oauth_refresh_tokens" - opaque refresh tokens (NOT JWTs, so they can never be used as access
 *                          tokens), each bound to the user, their roles, and the client. Authorization
 *                          codes are short-lived and live in the cache; access tokens are stateless JWTs.
 */
CREATE TABLE oauth_clients(
  client_id varchar(64) not null primary key,
  client_name text null,
  redirect_uris text not null,
  created timestamp not null default current_timestamp
);

CREATE TABLE oauth_refresh_tokens(
  token varchar(64) not null primary key,
  username text not null,
  roles text not null,
  client_id varchar(64) not null,
  created timestamp not null default current_timestamp
);
