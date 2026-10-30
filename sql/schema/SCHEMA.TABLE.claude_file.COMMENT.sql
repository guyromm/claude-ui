-- Name: TABLE claude_file; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON TABLE @SCHEMA@.claude_file IS 'files the chat page uploads (claude_upload, in chunks); the relay writes each to disk on delivery and types its path into the session';


--
