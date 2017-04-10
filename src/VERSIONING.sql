-- VERSIONING.sql
--
-- Author:      Felix Kunde <felix-kunde@gmx.de>
--
--              This skript is free software under the LGPL Version 3
--              See the GNU Lesser General Public License at
--              http://www.gnu.org/copyleft/lgpl.html
--              for more details.
-------------------------------------------------------------------------------
-- About:
-- This script provides functions to enable versioning of PostgreSQL databases
-- by using logged content from the audit tables.
-------------------------------------------------------------------------------
--
-- ChangeLog:
--
-- Version | Date       | Description                                       | Author
-- 0.4.4     2017-04-07   split up restore code to different functions        FKun
-- 0.4.3     2017-04-05   greatly improved performance for restoring          FKun
--                        using window functions with a FILTER
-- 0.4.2     2017-03-28   better logic to query tables if nothing found       FKun
--                        in logs (considers also rename events)
-- 0.4.1     2017-03-15   reflecting new DDL log table schema                 FKun
-- 0.4.0     2017-03-05   updated JSONB functions                             FKun
-- 0.3.0     2016-04-14   a new template mechanism for restoring              FKun
-- 0.2.2     2016-03-08   minor change to generate_log_entry function         FKun
-- 0.2.1     2016-02-14   removed unnecessary plpgsql and dynamic sql code    FKun
-- 0.2.0     2015-05-26   more efficient queries                              FKun
-- 0.1.0     2014-11-26   initial commit                                      FKun
--

/**********************************************************
* C-o-n-t-e-n-t:
*
* FUNCTIONS:
*   audit_table_check(IN tid BIGINT, IN tab_name TEXT, IN tab_schema TEXT,
*     OUT log_tab_oid OID, OUT log_tab_name TEXT, OUT log_tab_schema TEXT, OUT log_tab_id INTEGER,
*     OUT recent_tab_name TEXT, OUT recent_tab_schema TEXT, OUT recent_tab_id INTEGER, OUT recent_tab_upper_txid NUMERIC) RETURNS RECORD
*   create_restore_template(tid BIGINT, template_name TEXT, table_name TEXT, schema_name TEXT, preserve_template INTEGER DEFAULT 0) RETURNS SETOF VOID
*   generate_log_entries(start_from_tid BIGINT, end_at_tid BIGINT, table_name TEXT, schema_name TEXT) RETURNS SETOF jsonb
*   generate_log_entry(start_from_tid BIGINT, end_at_tid BIGINT, table_name TEXT, schema_name TEXT, aid BIGINT) RETURNS jsonb
*   log_schema_state(schemaname TEXT DEFAULT 'public') RETURNS SETOF VOID
*   log_table_state(table_name TEXT, schema_name TEXT DEFAULT 'public') RETURNS SETOF VOID
*   restore_query(start_from_tid BIGINT, end_at_tid BIGINT, table_name TEXT, schema_name TEXT, aid BIGINT DEFAULT NULL) RETURNS TEXT
*   restore_schema_state(start_from_tid BIGINT, end_at_tid BIGINT, original_schema_name TEXT, target_schema_name TEXT, 
*     target_table_type TEXT DEFAULT 'VIEW', update_state INTEGER DEFAULT '0') RETURNS SETOF VOID
*   restore_table_state(start_from_tid BIGINT, end_at_tid BIGINT, original_table_name TEXT, original_schema_name TEXT, 
*     target_schema_name TEXT, target_table_type TEXT DEFAULT 'VIEW') RETURNS SETOF VOID
***********************************************************/

/**********************************************************
* AUDIT TABLE CHECK
*
* Helper function to check if requested table has existed
* before tid happened and if the name has named 
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.audit_table_check(
  IN tid BIGINT,
  IN tab_name TEXT,
  IN tab_schema TEXT,
  OUT log_tab_oid OID,
  OUT log_tab_name TEXT,
  OUT log_tab_schema TEXT,
  OUT log_tab_id INTEGER,
  OUT recent_tab_name TEXT,
  OUT recent_tab_schema TEXT,
  OUT recent_tab_id INTEGER,
  OUT recent_tab_upper_txid NUMERIC
  ) RETURNS RECORD AS
$$
DECLARE
  log_tab_upper_txid NUMERIC;
BEGIN
  -- try to get OID of table
  BEGIN
    log_tab_oid := ($3 || '.' || $2)::regclass::oid;

    EXCEPTION
      WHEN OTHERS THEN
        -- check if the table exists in audit_table_log
        SELECT relid INTO log_tab_oid
          FROM pgmemento.audit_table_log
            WHERE schema_name = $3
              AND table_name = $2
              LIMIT 1;

      IF log_tab_oid IS NULL THEN
        RAISE NOTICE 'Could not find table ''%'' in log tables.', $2;
        RETURN;
      END IF;
  END;

  -- check if the table existed when tid happened
  -- save schema and name in case it was renamed
  SELECT id, schema_name, table_name, upper(txid_range)
    INTO log_tab_id, log_tab_schema, log_tab_name, log_tab_upper_txid 
    FROM pgmemento.audit_table_log 
      WHERE relid = log_tab_oid
        AND txid_range @> $1::numeric;

  IF NOT FOUND THEN
    RAISE NOTICE 'Table ''%'' did not exist for requested txid range.', $3;
    RETURN;
  END IF;

  -- take into account that the table might not exist anymore or it has been renamed
  -- try to find out if there is an active table with the same oid
  IF log_tab_upper_txid IS NOT NULL THEN
    SELECT id, schema_name, table_name, upper(txid_range)
      INTO recent_tab_id, recent_tab_schema, recent_tab_name, recent_tab_upper_txid
      FROM pgmemento.audit_table_log 
      WHERE relid = log_tab_oid
        AND upper(txid_range) IS NULL;
  END IF;

  -- if not, set new_tab_* attributes, as we need them later
  IF recent_tab_id IS NULL THEN
    recent_tab_id := log_tab_id;
    recent_tab_schema := log_tab_schema;
    recent_tab_name := log_tab_name;
    recent_tab_upper_txid := log_tab_upper_txid;
  END IF;

  RETURN;
END;
$$
LANGUAGE plpgsql;


/**********************************************************
* RESTORE QUERY
*
* Helper function to produce query string for restore
* single or multiple log entries (depends if aid is given)
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.restore_query(
  start_from_tid BIGINT,
  end_at_tid BIGINT,
  table_name TEXT,
  schema_name TEXT,
  aid BIGINT DEFAULT NULL
  ) RETURNS TEXT AS
$$
DECLARE
  tab_oid OID;
  tab_id INTEGER;
  tab_name TEXT;
  tab_schema TEXT;
  new_tab_id INTEGER;
  new_tab_name TEXT;
  new_tab_schema TEXT;
  new_tab_upper_txid NUMERIC;
  query_text TEXT;
  log_column RECORD;
  v_columns TEXT := '';
  v_columns_count NUMERIC := 0;
  delimiter VARCHAR(1) := '';
  new_column_name TEXT;
  find_logs TEXT := '';
  join_recent_state BOOLEAN := FALSE;
BEGIN
  -- set variables
  SELECT log_tab_oid, log_tab_name, log_tab_schema, log_tab_id, recent_tab_name, recent_tab_schema, recent_tab_id, recent_tab_upper_txid
    INTO tab_oid, tab_name, tab_schema, tab_id, new_tab_name, new_tab_schema, new_tab_id, new_tab_upper_txid
    FROM pgmemento.audit_table_check($2,$3,$4);

  -- start building the SQL command
  query_text := 'SELECT jsonb_build_object(';

  -- loop over all columns and query the historic value for each column separately
  FOR log_column IN 
    SELECT column_name, ordinal_position, data_type, data_type_name
      FROM pgmemento.audit_column_log 
        WHERE audit_table_id = tab_id
          AND txid_range @> $2::numeric
          ORDER BY ordinal_position
  LOOP
    new_column_name := NULL;

    -- columns to be fed into jsonb_build_object function (requires alternating order of keys and values)
    v_columns_count := v_columns_count + 1;
    query_text := query_text 
      || delimiter || E'\n'
      || '  q.key' || v_columns_count || E',\n' 
      || '  q.value' || v_columns_count
      -- use ->>0 to extract first element from jsonb logs
      || '->>0';

    -- extend subquery string to retrieve historic values
    find_logs := find_logs
      || delimiter || E'\n'
      -- key: use historic name
      || format('    %L::text AS key', log_column.column_name) || v_columns_count || E',\n'
      -- value: query logs with given key
      || E'    COALESCE(\n'
      || format(E'      jsonb_agg(a.changes -> %L) FILTER (WHERE a.changes ? %L) OVER (ORDER BY a.id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING),\n',
           log_column.column_name, log_column.column_name
         );

    -- if column is not found in the row_log table, recent state has to be queried if table exists
    -- additionally, check if column still exists
    SELECT column_name INTO new_column_name
      FROM pgmemento.audit_column_log
        WHERE audit_table_id = new_tab_id
          AND ordinal_position = log_column.ordinal_position
          AND data_type = log_column.data_type
          AND data_type_name = log_column.data_type_name
          AND upper(txid_range) IS NULL;

    IF new_tab_upper_txid IS NOT NULL OR new_column_name IS NULL THEN
      -- there is either no existing table or column
      IF tab_name <> new_tab_name THEN
        RAISE NOTICE 'No matching field found for column ''%'' in active table ''%.%'' (formerly known as ''%.%'').',
                        log_column.column_name, new_tab_schema, new_tab_name, tab_schema, tab_name;
      ELSE
        RAISE NOTICE 'No matching field found for column ''%'' in active table ''%.%''.',
                        log_column.column_name, new_tab_schema, new_tab_name;
      END IF;
    ELSE
      -- take current value from matching column (and hope that the data is really fitting)
      find_logs := find_logs 
        || format(E'      to_jsonb(x.%I),\n', new_column_name);
      join_recent_state := TRUE;
    END IF;

    -- if nothing is found in the logs or in the recent state value will be NULL
    find_logs := find_logs
      || E'      NULL\n';

    -- complete the substring for given column
    find_logs := find_logs
      || '    ) AS value' || v_columns_count;
    delimiter := ',';
  END LOOP;

  -- finish restore query
  query_text := query_text
    -- complete SELECT part
    || E'\n  ) AS log_entry\n'
    -- add FROM block q that extracts the correct jsonb values
    || E'FROM (\n'
    -- use DISTINCT ON to get only one row
    || '  SELECT DISTINCT ON (a.audit_id'
    || CASE WHEN join_recent_state THEN
         ', x.audit_id'
       ELSE
         ''
       END
    || ')'
    -- add column selection that has been set up above 
    || find_logs
    -- add subquery f to get last event for given audit_id before given transaction
    || E'\n  FROM (\n'
    || E'    SELECT DISTINCT ON (r.audit_id) r.audit_id, r.event_id, e.op_id\n'
    || E'      FROM pgmemento.row_log r\n'
    || E'      JOIN pgmemento.table_event_log e ON e.id = r.event_id\n'
    || E'      JOIN pgmemento.transaction_log t ON t.txid = e.transaction_id\n'
    || format(E'        WHERE t.txid >= %L AND t.txid < %L\n', $1, $2)
    || CASE WHEN $5 IS NULL THEN
         format(E'          AND e.table_relid = %L\n', tab_oid)
       ELSE
         format(E'          AND r.audit_id = %L\n', $5)
       END
    || E'        ORDER BY r.audit_id, e.id DESC\n'
    || E'  ) f\n'
    -- left join on row_log table and consider only events younger than the one extracted in subquery f
    || E'  LEFT JOIN pgmemento.row_log a ON a.audit_id = f.audit_id AND a.event_id > f.event_id\n'
    -- left join on actual table to get the recent value for a field if nothing is found in the logs
    || CASE WHEN join_recent_state THEN
         format(E'  LEFT JOIN %I.%I x ON x.audit_id = f.audit_id\n', new_tab_schema, new_tab_name)
       ELSE
         ''
       END
    -- do not produce a result if row with audit_id did not exist before given transaction
    -- could be if filtered event has been either DELETE or TRUNCATE
    || E'    WHERE f.op_id < 3\n'
    -- order by oldest log entry for given audit_id
    || '    ORDER BY a.audit_id, '
    || CASE WHEN join_recent_state THEN
         'x.audit_id, '
       ELSE
         ''
       END
    || E' a.id\n'
    -- closing FROM block q
    || E') q\n';

  RETURN query_text;
END;
$$
LANGUAGE plpgsql;


/**********************************************************
* GENERATE LOG ENTRY/ENTRIES
*
* Functions to reproduce historic JSONB tuples for given
* transaction range
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.generate_log_entry(
  start_from_tid BIGINT,
  end_at_tid BIGINT,
  table_name TEXT,
  schema_name TEXT,
  aid BIGINT
  ) RETURNS jsonb AS
$$
DECLARE
  -- init query string
  restore_query TEXT := pgmemento.restore_query($1, $2, $3, $4, $5);
  jsonb_result JSONB := '{}'::jsonb;
BEGIN
  -- execute the SQL command
  EXECUTE restore_query INTO jsonb_result;
  RETURN jsonb_result;
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION pgmemento.generate_log_entries(
  start_from_tid BIGINT,
  end_at_tid BIGINT,
  table_name TEXT,
  schema_name TEXT
  ) RETURNS SETOF jsonb AS
$$
DECLARE
  -- init query string
  restore_query TEXT := pgmemento.restore_query($1, $2, $3, $4);
BEGIN
  -- execute the SQL command
  RETURN QUERY EXECUTE restore_query;
END;
$$
LANGUAGE plpgsql;


/**********************************************************
* CREATE RESTORE TEMPLATE
*
* Function to create a temporary table to be used as a
* historically correct template for restoring data with
* jsonb_populate_record function 
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.create_restore_template(
  tid BIGINT,
  template_name TEXT,
  table_name TEXT,
  schema_name TEXT,
  preserve_template INTEGER DEFAULT 0
  ) RETURNS SETOF VOID AS
$$
DECLARE
  ddl_command TEXT := format('CREATE TEMPORARY TABLE %I (', $2);
  delimiter VARCHAR(1) := '';
  log_column RECORD;
BEGIN
  -- get columns that exist at transaction with id end_at_tid
  FOR log_column IN
    SELECT c.column_name, c.column_default, c.is_nullable, c.data_type_name, c.char_max_length, 
           c.numeric_precision, c.numeric_scale, c.datetime_precision, c.interval_type
      FROM pgmemento.audit_column_log c
      JOIN pgmemento.audit_table_log t ON t.id = c.audit_table_id
        WHERE t.schema_name = $4
          AND t.table_name = $3
          AND t.txid_range @> $1::numeric
          AND c.txid_range @> $1::numeric
          ORDER BY ordinal_position
  LOOP
    ddl_command := ddl_command || delimiter || log_column.column_name || ' ' || log_column.data_type_name ||
    CASE WHEN log_column.char_max_length IS NOT NULL
      THEN '('||log_column.char_max_length||')' ELSE '' END ||
    CASE WHEN log_column.numeric_precision IS NOT NULL 
      AND log_column.data_type_name = 'numeric' 
      THEN '('||log_column.numeric_precision||','||log_column.numeric_scale||')' ELSE '' END ||
    CASE WHEN log_column.datetime_precision IS NOT NULL 
      AND NOT log_column.data_type_name = 'date' 
      AND log_column.interval_type IS NULL 
      THEN '('||log_column.datetime_precision||')' ELSE '' END ||
    CASE WHEN log_column.interval_type IS NOT NULL 
      THEN ' ' || log_column.interval_type ELSE '' END ||
    CASE WHEN log_column.is_nullable IS NOT NULL 
      THEN ' NOT NULL' ELSE '' END ||
    CASE WHEN log_column.column_default IS NOT NULL 
      THEN ' DEFAULT ' || log_column.column_default ELSE '' END;
    delimiter := ',';
  END LOOP;

  -- create temp table
  IF delimiter = ',' THEN
    ddl_command := ddl_command || ') ' ||
      CASE WHEN $5 <> 0 THEN 'ON COMMIT PRESERVE ROWS' ELSE 'ON COMMIT DROP' END;
    EXECUTE ddl_command;
  ELSE
    RETURN;
  END IF;
END;
$$
LANGUAGE plpgsql;


/**********************************************************
* RESTORE TABLE STATE
*
* See what the table looked like at a given date.
* The table state will be restored in a separate schema.
* The user can choose if it will appear as a TABLE or VIEW.
***********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.restore_table_state(
  start_from_tid BIGINT,
  end_at_tid BIGINT,
  original_table_name TEXT,
  original_schema_name TEXT,
  target_schema_name TEXT,
  target_table_type TEXT DEFAULT 'VIEW',
  update_state INTEGER DEFAULT '0'
  ) RETURNS SETOF VOID AS
$$
DECLARE
  replace_view TEXT := '';
  tab_oid OID;
  tab_id INTEGER;
  tab_name TEXT;
  tab_schema TEXT;
  new_tab_id INTEGER;
  new_tab_name TEXT;
  new_tab_schema TEXT;
  template_name TEXT;
  restore_query TEXT;
BEGIN
  -- test if target schema already exist
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.schemata 
      WHERE schema_name = $5
  ) THEN
    EXECUTE format('CREATE SCHEMA %I', $5);
  END IF;

  -- test if table or view already exist in target schema
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
      WHERE table_name = $3
        AND table_schema = $5
        AND (table_type = 'BASE TABLE' OR table_type = 'VIEW')
  ) THEN
    IF $7 = 1 THEN
      IF $6 = 'TABLE' THEN
        -- drop the table state
        PERFORM drop_table_state($3, $5);
      ELSE
        replace_view := 'OR REPLACE ';
      END IF;
    ELSE
      RAISE EXCEPTION 'Entity ''%'' in schema ''%'' does already exist. Either delete the table or choose another name or target schema.',
                         $3, $5;
    END IF;
  END IF;

  -- set variables
  SELECT log_tab_oid, log_tab_name, log_tab_schema, log_tab_id, recent_tab_name, recent_tab_schema
    INTO tab_oid, tab_name, tab_schema, tab_id, new_tab_name, new_tab_schema
    FROM pgmemento.audit_table_check($2,$3,$4);

  -- create a temporary table used as template for jsonb_populate_record
  template_name := $3 || '_tmp' || trunc(random() * 99999 + 1);

  -- create a temporary table used as template for jsonb_populate_record
  PERFORM pgmemento.create_restore_template($2, template_name, tab_name, tab_schema, CASE WHEN $6 = 'TABLE' THEN 0 ELSE 1 END);

  -- check if logging entries exist in the audit_log table
  IF EXISTS (
    SELECT 1 FROM pgmemento.table_event_log 
      WHERE table_relid = tab_oid
      LIMIT 1
  ) THEN
    -- let's go back in time - restore a table state for given transaction interval
    IF upper($6) = 'VIEW' OR upper($6) = 'TABLE' THEN
      restore_query := 'CREATE ' 
        || replace_view || $6 
        || format(E' %I.%I AS\n', $5, tab_name)
        -- select all rows from result of jsonb_populate_record function
        || E'  SELECT p.*\n'
        -- use generate_log_entries function to produce JSONB tuples
        || format(E'    FROM pgmemento.generate_log_entries(%L,%L,%L,%L) AS log_entry\n', $1, $2, $3, $4)
        -- pass reconstructed tuples to jsonb_populate_record function
        || E'    JOIN LATERAL (\n'
        || format(E'      SELECT * FROM jsonb_populate_record(null::%I, log_entry)\n', template_name)
        || '    ) p ON (true)';

      -- finally execute query string
      EXECUTE restore_query;
    ELSE
      RAISE NOTICE 'Table type ''%'' not supported. Use ''VIEW'' or ''TABLE''.', $6;
    END IF;
  ELSE
    -- no entries found in log table - table is regarded empty
    IF tab_name <> new_tab_name THEN
      RAISE NOTICE 'Did not found entries in log table for table ''%.%'' (formerly known as ''%.%'').',
                      new_tab_schema, new_tab_name, tab_schema, tab_name;
    ELSE
      RAISE NOTICE 'Did not found entries in log table for table ''%.%''.',
                      new_tab_schema, new_tab_name;
    END IF;
    IF upper($6) = 'TABLE' THEN
      EXECUTE format('CREATE TABLE %I.%I AS SELECT * FROM %I', $5, tab_name, template_name);
    ELSIF upper($6) = 'VIEW' THEN
      EXECUTE format('CREATE ' || replace_view || 'VIEW %I.%I AS SELECT * FROM %I.%I LIMIT 0', $5, tab_name, $4, new_tab_name);        
    ELSE
      RAISE NOTICE 'Table type ''%'' not supported. Use ''VIEW'' or ''TABLE''.', $6;
    END IF;
  END IF;
END;
$$
LANGUAGE plpgsql;

-- perform restore_table_state on multiple tables in one schema
CREATE OR REPLACE FUNCTION pgmemento.restore_schema_state(
  start_from_tid BIGINT,
  end_at_tid BIGINT,
  original_schema_name TEXT,
  target_schema_name TEXT, 
  target_table_type TEXT DEFAULT 'VIEW',
  update_state INTEGER DEFAULT '0'
  ) RETURNS SETOF VOID AS
$$
SELECT pgmemento.restore_table_state(
  $1, $2, table_name, schema_name, $4, $5, $6
) FROM pgmemento.audit_table_log 
  WHERE schema_name = $3
    AND txid_range @> $2::numeric;
$$
LANGUAGE sql;


/**********************************************************
* LOG TABLE STATE
*
* Log table content in the audit_log table (as inserted values)
* to have a baseline for table versioning.
**********************************************************/
CREATE OR REPLACE FUNCTION pgmemento.log_table_state(
  original_table_name TEXT,
  original_schema_name TEXT DEFAULT 'public'
  ) RETURNS SETOF VOID AS
$$
DECLARE
  is_empty INTEGER := 0;
  e_id INTEGER;
  pkey_columns TEXT := '';
BEGIN
  -- first, check if table is not empty
  EXECUTE format(
    'SELECT 1 FROM %I.%I LIMIT 1',
    $2, $1)
    INTO is_empty;

  IF is_empty <> 0 THEN
    -- fill transaction_log table 
    INSERT INTO pgmemento.transaction_log
      (txid, stmt_date, user_name, client_name)
    VALUES 
      (txid_current(), statement_timestamp(), current_user, inet_client_addr())
    ON CONFLICT (txid)
      DO NOTHING;

    -- fill table_event_log table  
    INSERT INTO pgmemento.table_event_log
      (transaction_id, op_id, table_operation, table_relid) 
    VALUES
      (txid_current(), 1, 'INSERT', ($2 || '.' || $1)::regclass::oid)
    ON CONFLICT (transaction_id, table_relid, op_id)
      DO NOTHING
      RETURNING id INTO e_id;

    -- fill row_log table
    IF e_id IS NOT NULL THEN
      -- get the primary key columns
      SELECT array_to_string(array_agg(pga.attname),',') INTO pkey_columns
        FROM pg_index pgi, pg_class pgc, pg_attribute pga 
          WHERE pgc.oid = ($2 || '.' || $1)::regclass::oid
            AND pgi.indrelid = pgc.oid 
            AND pga.attrelid = pgc.oid 
            AND pga.attnum = ANY(pgi.indkey) AND pgi.indisprimary;

      IF pkey_columns IS NOT NULL THEN
        pkey_columns := ' ORDER BY ' || pkey_columns;
      END IF;

      EXECUTE format(
        'INSERT INTO pgmemento.row_log (event_id, audit_id, changes)
           SELECT $1, audit_id, NULL::jsonb AS changes FROM %I.%I' || pkey_columns,
           $2, $1) USING e_id;
    END IF;
  END IF;
END;
$$
LANGUAGE plpgsql;

-- perform log_table_state on multiple tables in one schema
CREATE OR REPLACE FUNCTION pgmemento.log_schema_state(
  schemaname TEXT DEFAULT 'public'
  ) RETURNS SETOF VOID AS
$$
SELECT pgmemento.log_table_state(a.table_name, a.schema_name)
  FROM pgmemento.audit_table_log a, pgmemento.audit_tables_dependency d
    WHERE a.schema_name = d.schemaname
      AND a.table_name = d.tablename
      AND a.schema_name = $1
      AND d.schemaname = $1
      AND upper(txid_range) IS NULL
      ORDER BY d.depth;
$$
LANGUAGE sql;