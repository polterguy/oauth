CREATE TABLE IF NOT EXISTS oauth_refresh_tokens(
  token varchar(64) not null primary key,
  username text not null,
  roles text not null,
  client_id varchar(64) not null,
  created timestamp not null default current_timestamp
);
