-- Name: TABLE claude_status; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON TABLE @SCHEMA@.claude_status IS 'Is the Claude session WORKING or WAITING for the user? Derived by claude_voice_relay from the LAST
  transcript record, not from file mtime: a long tool call writes nothing for minutes while the
  session is very much working, so an activity timeout would report ''waiting'' in the middle of a
  10-minute command. Record type is the honest signal -- a turn is over only when the assistant''s
  last block is text with no tool_use pending.';


--
