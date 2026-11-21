-- Name: claude_ctl claude_ctl_wake; Type: TRIGGER; Schema: @SCHEMA@; Owner: -
--

CREATE OR REPLACE TRIGGER claude_ctl_wake AFTER INSERT ON @SCHEMA@.claude_ctl FOR EACH ROW EXECUTE FUNCTION @SCHEMA@.claude_wake();


--
