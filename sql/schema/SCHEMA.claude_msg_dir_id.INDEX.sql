-- Name: claude_msg_dir_id; Type: INDEX; Schema: @SCHEMA@; Owner: -
--

CREATE INDEX claude_msg_dir_id ON @SCHEMA@.claude_msg USING btree (direction, id);


--
