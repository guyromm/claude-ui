-- Name: claude_msg_src_uuid; Type: INDEX; Schema: @SCHEMA@; Owner: -
--

CREATE UNIQUE INDEX claude_msg_src_uuid ON @SCHEMA@.claude_msg USING btree (src_uuid);


--
