-- Name: claude_msg; Type: VIEW; Schema: api; Owner: -
--

CREATE OR REPLACE VIEW api.claude_msg AS
 SELECT id,
    ts,
    direction,
    body,
    suggest
   FROM @SCHEMA@.claude_msg m
  WHERE (@ADMIN@ AND ((direction = 'out'::text) OR ((direction <> 'out'::text) AND (src_uuid IS NULL)) OR ((direction <> 'out'::text) AND (src_uuid IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
           FROM @SCHEMA@.claude_msg d
          WHERE ((d.src_uuid IS NULL) AND (d.direction = m.direction) AND (regexp_replace(d.body, '\s+'::text, ' '::text, 'g'::text) = regexp_replace(m.body, '\s+'::text, ' '::text, 'g'::text)) AND ((d.ts >= (m.ts - '00:10:00'::interval)) AND (d.ts <= (m.ts + '00:10:00'::interval))))))))))
  ORDER BY id;


--
