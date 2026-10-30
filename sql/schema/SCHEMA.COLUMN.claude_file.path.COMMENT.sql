-- Name: COLUMN claude_file.path; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON COLUMN @SCHEMA@.claude_file.path IS 'set by the relay once the file is written to disk; an upload with a path is sealed (no more chunks)';


--
