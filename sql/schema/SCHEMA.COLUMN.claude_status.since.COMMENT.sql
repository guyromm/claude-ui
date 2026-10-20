-- Name: COLUMN claude_status.since; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON COLUMN @SCHEMA@.claude_status.since IS 'When the CURRENT state began, so the UI can show how long it has been working (or idle) rather than
  just a dot. Only moves when the state CHANGES.';


--
