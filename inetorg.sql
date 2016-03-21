BEGIN;

CREATE SCHEMA IF NOT EXISTS inetorg;
SET LOCAL search_path TO inetorg, public;

CREATE TABLE cat (
  license       uuid PRIMARY KEY,
  responds_to   text NOT NULL,
  doglike       boolean DEFAULT TRUE
);

CREATE TABLE walrus (
  registration  uuid PRIMARY KEY,
  nickname      text,
  size          text NOT NULL DEFAULT 'big' CHECK (size IN ('small', 'big')),
  haz_bucket    boolean NOT NULL DEFAULT FALSE
);

CREATE TABLE animal (
  ident         uuid PRIMARY KEY
);

END;
