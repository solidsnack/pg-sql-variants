BEGIN;

CREATE SCHEMA IF NOT EXISTS variants;
SET LOCAL search_path TO variants, meta, public;


--- Add a variant to tagged union. The variant's primary key must be columns
--- of the same type in the same order as the tagged union's. (They don't need
--- to have the same names.)
CREATE FUNCTION variant(base regclass, variant regclass) RETURNS void AS $code$
DECLARE
  view_name      text := quote_ident(tablename(base)||'*');
  trigger_base   text := tablename(base)||':'||tablename(variant);
  insert_trigger text := quote_ident(trigger_base||'/i');
  update_trigger text := quote_ident(trigger_base||'/u');
  delete_trigger text := quote_ident(trigger_base||'/d');
  ns             text := quote_ident(schemaname(variant));
  tabs           regclass[];
  selects        text[];
BEGIN
  SELECT tables INTO tabs FROM variants WHERE tab = base;

  tabs := COALESCE(tabs, ARRAY[]::regclass[]) || variant;

  --- Collect table information now, before changing the search path, to use
  --- for rebuilding the view, later.
  WITH expanded AS
   (SELECT tab,
           array_agg('NULL::'||tab)
            OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS a,
           array_agg('NULL::'||tab)
            OVER (ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS z
      FROM unnest(tabs) AS _(tab))
  SELECT array_agg($$
    SELECT $$|| quote_cols(cols) ||$$,
           tableoid::regclass,
           $$|| fields ||$$
      FROM $$|| tab ||$$ AS tab
  $$) INTO STRICT selects
    FROM pk NATURAL JOIN expanded,
         array_to_string((a[1:cardinality(a)-1] || ARRAY['(tab)'])
                         || z[2:cardinality(z)], ', ', 'NULL') AS fields;

  --- Update metadata table.
  DELETE FROM variants WHERE tab = base;
  INSERT INTO variants VALUES (base, tabs);

  --- Mark base as a variant type.
  BEGIN
    EXECUTE $$
      ALTER TABLE $$|| base ||$$ INHERIT variants.variant;
    $$;
  EXCEPTION WHEN duplicate_table THEN END;
  --- Strange but true: duplicate_table is thrown when we try to inherit from
  --- a table we already inherit from.

  EXECUTE $$
    SET LOCAL search_path TO $$|| ns ||$$, public;

  ----- Setup the foreign key linking variant to base.

    --- Ensures constraint will validate at the end of the transaction.
    INSERT INTO $$|| base ||$$ SELECT $$||
      quote_cols(pk(variant))
    ||$$ FROM $$|| variant ||$$;

    ALTER TABLE $$|| variant ||$$ ADD FOREIGN KEY ($$||
      quote_cols(pk(variant))
    ||$$)
     REFERENCES $$|| base ||$$
                ON UPDATE CASCADE ON DELETE CASCADE
                DEFERRABLE INITIALLY DEFERRED;

  ----- Create the triggers that propagate changes to base.

    CREATE OR REPLACE FUNCTION $$|| insert_trigger ||$$()
    RETURNS trigger AS $t$
    BEGIN
      INSERT INTO $$|| base ||$$ VALUES ($$|| inserter(pk(variant)) ||$$);
      RETURN NEW;
    END
    $t$ LANGUAGE plpgsql;
    CREATE TRIGGER $$|| insert_trigger ||$$
    BEFORE INSERT ON $$|| variant ||$$ FOR EACH ROW
    EXECUTE PROCEDURE $$|| insert_trigger ||$$();

    CREATE OR REPLACE FUNCTION $$|| update_trigger ||$$()
    RETURNS trigger AS $t$
    BEGIN
      UPDATE $$|| base || setter(pk(base), pk(variant)) ||$$;
      RETURN NEW;
    END
    $t$ LANGUAGE plpgsql;
    CREATE TRIGGER $$|| update_trigger ||$$ AFTER UPDATE OF $$||
      quote_cols(pk(variant))
    ||$$ ON $$|| variant ||$$ FOR EACH ROW
    EXECUTE PROCEDURE $$|| update_trigger ||$$();

    CREATE OR REPLACE FUNCTION $$|| delete_trigger ||$$()
    RETURNS trigger AS $t$
    BEGIN
      DELETE FROM $$|| base || deleter(pk(base), pk(variant)) ||$$;
      RETURN OLD;
    END
    $t$ LANGUAGE plpgsql;
    CREATE TRIGGER $$|| delete_trigger ||$$
    AFTER DELETE ON $$|| variant ||$$ FOR EACH ROW
    EXECUTE PROCEDURE $$|| delete_trigger ||$$();

  ----- Rebuild the view.

    CREATE OR REPLACE VIEW $$|| view_name ||$$ ($$||
      quote_cols(pk(base))
    ||$$, type, $$||
      quote_cols(tabs)
    ||$$) AS$$|| array_to_string(selects, '   UNION ALL')||$$
  $$;
END
$code$ LANGUAGE plpgsql SET search_path FROM CURRENT;


CREATE TABLE variants (
  tab           regclass NOT NULL,
  tables        regclass[] NOT NULL DEFAULT '{}'
);


--- Marker table -- every variant base inherits from this table.
CREATE TABLE variant ();


CREATE FUNCTION quote_cols(cols name[]) RETURNS text AS $$
  SELECT string_agg(quote_ident(col), ', ') FROM unnest(cols) AS col
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION quote_cols(cols regclass[]) RETURNS text AS $$
  SELECT string_agg(quote_ident(tablename(col)), ', ') FROM unnest(cols) AS col
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION inserter(cols name[])
RETURNS text AS $$
  SELECT string_agg('NEW.'||quote_ident(col), ', ') FROM unnest(cols) AS col
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION setter(left_cols name[], right_cols name[])
RETURNS text AS $$
  SELECT ' SET '||string_agg(ql||' = NEW.'||qr, ', ')
     ||' WHERE '||string_agg(ql||' = OLD.'||qr, ', ')
    FROM unnest(left_cols, right_cols) AS _(left_col, right_col),
         quote_ident(left_col) AS ql,
         quote_ident(right_col) AS qr
$$ LANGUAGE sql IMMUTABLE STRICT;

CREATE FUNCTION deleter(left_cols name[], right_cols name[])
RETURNS text AS $$
  SELECT ' WHERE '||string_agg(ql||' = OLD.'||qr, ', ')
    FROM unnest(left_cols, right_cols) AS _(left_col, right_col),
         quote_ident(left_col) AS ql,
         quote_ident(right_col) AS qr
$$ LANGUAGE sql IMMUTABLE STRICT;

END;
