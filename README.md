Modeling Variant Types in Postgres
==================================

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
support for polymorphism that is helpful to object-oriented languages,
languages like Go which have only structs and traits (interfaces), and
languages like Haskell and Rust which provide sum of product types as well as
traits.

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



Worked example
--------------

```sql
CREATE TABLE cat (
  cat           uuid PRIMARY KEY,
  responds_to   text NOT NULL,
  meows         boolean NOT NULL DEFAULT TRUE
);

CREATE TABLE person (
  person        uuid PRIMARY KEY,
  fullname      text NOT NULL,
  difficult     boolean NOT NULL DEFAULT FALSE
);

CREATE TABLE walrus (
  walrus        uuid PRIMARY KEY,
  nickname      text NOT NULL,
  bucket        text NOT NULL DEFAULT 'haz' CHECK (bucket IN ('haz', 'no'))
);
```

Of course, every user has a `login` -- a unique handle, password and email that serves to identify their account.

```sql
CREATE TABLE login (
  nick          text UNIQUE NOT NULL,
  email         text UNIQUE NOT NULL,
  pass          bytea NOT NULL
);
```

We'd like to associate the `login` to a user; and we'd like to do so without
making the login name a primary key (it would be natural to allow a user to
change it, for example). In the language of ActiveRecord, logins `belong_to`
their user.


A Foreign Key
-------------

A widely accepted solution to this problem is "Class Table Inheritance". It is
sometimes pointed that class table inheritance should be used when a) we have
models that share many attributes but b) not too many. The idea is if the
models are "physically compatible" they can be interface compatible.

This kind of compatiblity -- an abstraction equivalent to traits or interfaces
-- can be implemented in Postgres `INHERITS`. The `INHERITS` keyword causes
one table to include all the column definitions of another -- and when one
table inherits from another, it also shows up in all queries over the latter.

In constrast to class hierarchies, the variants in an ADT (or in a case class)
rarely have fields in common. (The natural way to unify them if they do is
with a trait.) There is not necessarily any superset of traits which could be
used to form a parent table. What we are looking for here is a way to allow a
foreign key to point to one of many alternatives.

It is at this point that one may opine: a foreign key is but one way to
implement the requirement, that an X be a Y; this could also be done in the
application. Indeed, most anything can. Yet foreign keys and other forms of
database level validation retain a certain currency; they serve both to
document the data model and to make it trustworthy. There is something to be
said, also, for keeping validations close "physically" to definitions, to
ensure that insertion and validation succeed or fail together. Thus our
solution endeavours to remain "SQLy", preserving the ability to `INSERT`,
`SELECT` and `UPDATE` in the "obvious way".

For a foreign key to work at all, the variant tables -- `cat`, `person`,
`walrus`, in our example -- must all have a primary key of the same type. This
is in practice not difficult to arrange. Their primary key sets must also be
disjoint -- this is rather harder. And finally, there must be some
intermediate table to join through, so that `login` can declare a dependency
on some concrete table.

A reasonable person may at this point ask: what is point of joining through
this table if you can't select any columns of the target models? That is a
worthy question... One limitation of the solution proposed here is its
dependence on a functioning JSON datatype. JSON functions and operators have
yet to take a standard form within SQL and the code here presented is thus
vendor specific, tied to Postgres.


Foster Parents
--------------


