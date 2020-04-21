How To Use This Repo
====================

This repo provides utilities to for modeling variant types in Postgres and
provides a demo schema, as well. To try it out, first use Git to obtain the
relevant code:

```bash
:;  git clone git@github.com:solidsnack/pg-sql-variants.git
:;  cd pg-sql-variants/
:;  git submodule update --init --recursive
```

Then load the utilities and the sample schema in Postgres:

```sql
:;  psql
Line style is unicode.
Expanded display is used automatically.
Null display is "\N".
Timing is on.
psql (12.1)
Type "help" for help.

--# thelyfsoshort@[local]/~
\i init.psql 
BEGIN
...
COMMIT
...
BEGIN
...
COMMIT
...
BEGIN
...
COMMIT
...
```

The sample schema helps us to demonstrate a simple polymorhpic datatype: an
`animal` type with concrete `cat`, `dog` and `walrus` subtypes.

```sql
--# thelyfsoshort@[local]/~
SELECT tablename FROM pg_tables WHERE schemaname = 'inetorg';
 tablename
───────────
 cat
 walrus
 dog
 animal
(4 rows)
```

Let's setup the variant relationship between the types in the `inetorg`
namespace with the `variant()` function from the `variants` namespace:

```sql
--# thelyfsoshort@[local]/~
SET search_path TO inetorg, variants, "$user", public;

--# thelyfsoshort@[local]/~
SELECT * FROM variant('animal', 'cat');
SELECT * FROM variant('animal', 'walrus');
SELECT * FROM variant('animal', 'dog');
```

We can see that there are no `animal`s and there are no `cat`s:

```sql
--# thelyfsoshort@[local]/~
SELECT * FROM animal;
 ident 
───────
(0 rows)

--# thelyfsoshort@[local]/~
SELECT * FROM cat;
 license │ responds_to │ doglike
─────────┼─────────────┼─────────
(0 rows)
```

The `variants.variant()` function is basically a SQL macro; it sets up several
triggers every time it is called. Let's add a `cat`:

```sql
--# thelyfsoshort@[local]/~ 
INSERT INTO cat VALUES ('00000000-0000-0000-0000-000000000001', 'felix', FALSE);
INSERT 0 1
```

The triggers ensure that records are added to the `animal` table, as well.

```sql
--# thelyfsoshort@[local]/~
SELECT * FROM cat;
               license                │ responds_to │ doglike
──────────────────────────────────────┼─────────────┼─────────
 00000000-0000-0000-0000-000000000001 │ felix       │ f
(1 row)

--# thelyfsoshort@[local]/~
SELECT * FROM animal;
                ident                 
──────────────────────────────────────
 00000000-0000-0000-0000-000000000001
(1 row)
```

In addition to the triggers, `variants.variant()` also maintains a join table,
with one column for each variant type. In this case, the join table is named
`animal*`:

```sql
--# thelyfsoshort@[local]/~
SELECT * FROM "animal*";
Time: 0.285 ms
─[ RECORD 1 ]──────────────────────────────────────────
ident  │ 00000000-0000-0000-0000-000000000001
type   │ cat
cat    │ (00000000-0000-0000-0000-000000000001,felix,f)
walrus │ \N
dog    │ \N
(1 row)
```

The join table illustrates a cool Postgres features: columns with row types.

What good is a `cat`? Better delete while we're not sure:

```sql
--# thelyfsoshort@[local]/~
DELETE FROM cat;
DELETE 1
```

No more `cat`s, no more `animal*`s:

```sql
--# thelyfsoshort@[local]/~
SELECT * FROM cat;
 license │ responds_to │ doglike
─────────┼─────────────┼─────────
(0 rows)

--# thelyfsoshort@[local]/~
SELECT * FROM "animal*";
 ident │ type │ cat │ walrus │ dog
───────┼──────┼─────┼────────┼─────
(0 rows)
```

Our Approach to Variant Types in Postgres
=========================================

Typed variants, case classes, tagged unions, algebraic data types or
just [enums]: variant types are a feature common to many programming languages
but are an awkward fit for SQL.

[enums]: https://doc.rust-lang.org/book/enums.html

The fundamental difficulty is that foreign keys can reference columns of only
one other table. By combining `VIEW`s, triggers and Postgres's JSON data-type,
we can group related types like `cat` and `walrus` under a tagged union like
`animal`, allowing other tables to create foreign keys that reference
`animal`.

```sql
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
```

The process for forming the foreign key and triggers is completely formulaic
and we capture it in a stored procedure, `variant` (in `variants.sql`) that
allows one to put `cat` and `walrus` together under `animal`:

```sql
SELECT * FROM variant('animal', 'cat');
SELECT * FROM variant('animal', 'walrus');
```

Changes to keys are propagated bidirectionally between `animal` and its
variants. A `DELETE` against a cat's UUID in `animal` will remove the row from
`cat`; and a delete against `cat` will remove the row from `animal`.


Why data in your database is not like data in your app
------------------------------------------------------

Imagine for a moment the data loaded in your app. There are `Cat`s and
`Walrus`es of class `Animal`; there are `String`s, `Integer`s,
`StructTime`s... But how would you go about searching and sorting these
objects? One could say this is a bad question with a bad answer.

It's a bad question because most of the time we have the objects we need ready
to hand, assigned to variables in the right place in our program -- we don't
need to find them. We don't ever sort "all" integers, just the relevant ones.

The answer is bad because one would search and sort all the objects of a given
type by walking the heap. This might be facilitated by the runtime (Ruby's
`ObjectSpace.each_object(<cls>)` comes to mind) or it might not; but one is in
for a linear scan either way; and there is potential for conflict with other
threads of execution -- either preventing them from running, or tripping over
inconsistencies they introduce.

In a database, however, we do not rely on having the right context to find an
object. Whereas in a programming context we use the objects to get the fields,
in a storage context we use the fields to find the objects; there is no notion
of identity apart from field values. This is the heart of the
object-relational (or struct-enum-relational or ADT-relational) mismatch.

The two models overlap when we consider global, concurrent data structures
like event buses or concurrent maps. In SQL terms, each concurrent map would
be a relation, and in SQL each relation is a distinct type. A database is what
you would get if each of the types in your language were automatically
associated with a concurrent map.

There are two abstractions relating to types which become strange in this
all-types-backed-with-maps model:

* Inheritance, abstract base classes, and traits
* Generics (in the Java sense) or templates (in the C++ sense)

With regards to inheritance, one wonders what it would mean to insert an
`orange` in the `fruit` table or the `citrus` table. Clearly, inserting it in
any one of them should insert it in all of them. It is an ambiguity that gives
the author pause.

With regards to templated definitions, it stands to reason that these can have
no "live" representation in the database. Tables are there, or they aren't.
Perhaps a database's SQL dialect could support template expansion; but this
feature would have no impact on the nature of queries or relationships between
tables.


How tagged unions can help
--------------------------

Typed variants -- or tagged unions -- are a minimal way to expand SQL's
support for polymorphism that is helpful to object-oriented languages, and
languages like Haskell, Rust and Go which provide products or sums of products
as well as traits.

In our approach, the types which are part of the union are all themselves
physical tables with primary keys that are type compatible. We create a new
table for the union, the only columns of which are the columns of the primary
key and, through triggers, we ensure that inserts, updates and deletes to any
of the variant tables are also propagated to the union.

The union table ensures that the key spaces of the variants are disjoint and
allows for other tables to declare foreign keys that references the union.
Normal database validation logic takes over from there. The alternative would
be to have constraint triggers on each client table for each table in the
variant and to have triggers on each variant table for each client. This would
both be less expressive and a likely source of errors.

SQL tagged unions in this style support "composition" instead of inheritance
for polymorphism. For example, in the case where we have a type of letters and
would like be able handle Swiss letter, Spanish letter, Egyptian letter and
more, the modeller is tasked with breaking out the common fields into a
`letter` table which would reference `national_variant` which is a union of
`egyptian`, `ethiopian`, `etruscan` and so forth.

