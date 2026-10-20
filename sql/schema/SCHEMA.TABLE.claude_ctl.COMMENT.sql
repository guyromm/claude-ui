-- Name: TABLE claude_ctl; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON TABLE @SCHEMA@.claude_ctl IS 'Emergency control channel for /admin/voice: int=SIGINT once (interrupt current turn, like ESC), int2=SIGINT twice (Ctrl-C). The voice-relay delivers to the session''s claude pid. Admin-only.';


--
