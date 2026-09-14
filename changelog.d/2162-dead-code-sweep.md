### Changed

- Fourteen public functions with no caller left the server (#2162), found by a
  `mix_unused` sweep cross-checked against every test tree: the console
  queries the retired browser pages used (`list_conversations_by_activity/1`,
  `_unsafe_list_active_conversations/0`, `Team.list_addable_agents/1`,
  `Accounts.update_preferences/2`), four `_unsafe_` accessors nothing
  outside their own tests read, `Apps.new_conversation_url/0` and
  `Apps.team_url/1`, and the inference helpers `InferenceCredentials.has_own?/3`
  and `PlatformInference.serves?/3` that `resolve/4` superseded. The three
  conversation preference columns on `users` stay for now; nothing writes them.
