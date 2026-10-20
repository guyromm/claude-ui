-- Name: claude_status; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.claude_status AS
 SELECT state,
    detail,
    since,
    ts
   FROM @SCHEMA@.claude_status
  WHERE @ADMIN@;


--
