-- Name: claude_wake(); Type: FUNCTION; Schema: @SCHEMA@; Owner: -
--

CREATE OR REPLACE FUNCTION @SCHEMA@.claude_wake() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_notify('claude_ui_wake', TG_TABLE_NAME);
  RETURN NULL;
END $$;


--
