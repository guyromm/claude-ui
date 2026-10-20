-- Name: TABLE claude_img; Type: COMMENT; Schema: @SCHEMA@; Owner: -
--

COMMENT ON TABLE @SCHEMA@.claude_img IS 'Images shown inline in the claude-ui chat: bin/cui-img inserts one, a message references it as ![caption](cui-img:<id>), and the page fetches it through api.claude_img (admin-gated).';


--
