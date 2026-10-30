-- Name: claude_file; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.claude_file AS
 SELECT id,
    ts,
    name,
    mime,
    length(bytes) AS size,
    encode(bytes, 'base64'::text) AS b64
   FROM @SCHEMA@.claude_file
  WHERE @ADMIN@;


--
