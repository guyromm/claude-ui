-- Name: claude_img; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.claude_img AS
 SELECT id,
    ts,
    mime,
    caption,
    encode(bytes, 'base64'::text) AS b64
   FROM @SCHEMA@.claude_img
  WHERE @ADMIN@;


--
