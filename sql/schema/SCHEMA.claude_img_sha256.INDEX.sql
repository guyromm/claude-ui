-- Name: claude_img_sha256; Type: INDEX; Schema: @SCHEMA@; Owner: -
--

CREATE UNIQUE INDEX claude_img_sha256 ON @SCHEMA@.claude_img USING btree (sha256);


--
