-- Name: claude_msg claude_msg_wake; Type: TRIGGER; Schema: @SCHEMA@; Owner: -
--

CREATE OR REPLACE TRIGGER claude_msg_wake AFTER INSERT ON @SCHEMA@.claude_msg FOR EACH ROW WHEN (((new.direction = 'in'::text) AND (new.src_uuid IS NULL))) EXECUTE FUNCTION @SCHEMA@.claude_wake();


--
