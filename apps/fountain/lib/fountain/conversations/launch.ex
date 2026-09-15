defmodule Fountain.Conversations.Launch do
  @moduledoc """
  The channel door of a conversation launch: `start_or_resume_conversation/2`,
  the resume of a conversation already bound to a channel, the channel
  rotation it can be asked for, and the lookup a channel resolves to.

  Stage 7a of #2175 (one owner per conversation lifecycle verb). The fresh
  `start_conversation/2` clauses and `attach_conversation` stay in
  `Fountain.Conversations` until stages 7b and 7c; `Conversations` keeps a
  delegate for every public name here, so no caller moves.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Agents
  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, InferenceBinding}
  alias Fountain.InferenceCredentials
  alias Fountain.Repo

  @doc """
  Like `start_conversation/2`, but a conversation already bound to
  `attrs["channel_id"]` is resumed instead of a new one being opened.

  The channel key is opaque and client-supplied — a Buzz channel id from ACP
  `session/new` `_meta.channelId` (#774). A client that forgets its sessions
  (a restarted `buzz-acp`) then lands back on the same conversation, and so
  the same sandbox and workspace, rather than opening a fresh one per restart.

  Resumes the **latest live** conversation for the same user + agent + vault
  + environment override + channel — `terminated` and `failed` ones are past
  resuming, so a new one is opened and becomes the binding. So is one whose
  *sandbox* is `terminated` or `failed` (#779): the machine is gone, and the
  workspace with it, so the channel gets a new conversation on a working one
  rather than a continuous-looking transcript on a blank disk. A `suspended`
  sandbox is parked, not gone, and still resumes. Returns `{:ok, conv,
  :resumed}` or `{:ok, conv, :created}`; without a `channel_id` it always
  creates.

  `attrs["fresh"]` (`true`) skips the resume this once: the conversation
  currently bound to the channel is unbound (its `channel_id` cleared — it
  keeps running, and the sandbox reaper retires it like any other idle one)
  and a new one is opened as the binding. It is how a chat harness relays its
  owner's `!rotate` — ACP `session/new` `_meta.freshSession` — through a
  binding that would otherwise hand the old conversation straight back.
  Unbinding, rather than relying on "newest wins", keeps the outcome
  independent of `inserted_at`'s one-second precision. Admission commits the
  old unbinding and the replacement together. A refused replacement preserves
  the old binding; a later startup/prompt failure restores it unless another
  rotation has already moved the binding. Concurrent rotations of the same
  binding return a channel validation error to the loser.

  Two concurrent first calls for one channel can both create; the next call
  resumes whichever is newer. Nothing is audited on the resume path unless
  `attrs["labels"]` actually changes something: it is the same conversation,
  so labels merge into the row it hands back (#1637) and that write records
  `conversation.labels_set` like any other.
  """
  def start_or_resume_conversation(attrs, opts \\ [])

  def start_or_resume_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs,
        opts
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         :ok <- Conversations.check_execution_limits(user_id, attrs["execution_limits"]),
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, set_id} <-
           Conversations.resolve_inference_credential_id(
             attrs["inference_credential_id"],
             user_id,
             agent
           ) do
      case find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id, set_id) do
        %Conversation{} = conv ->
          if fresh_requested?(attrs) do
            with {:ok, fresh} <-
                   Conversations.start_conversation(
                     attrs,
                     Keyword.put(opts, :rotate_from, conv.id)
                   ),
                 do: {:ok, fresh, :created}
          else
            with {:ok, conv} <- resume_channel(conv, agent, attrs, opts),
                 do: {:ok, conv, :resumed}
          end

        nil ->
          with {:ok, conv} <- Conversations.start_conversation(attrs, opts),
               do: {:ok, conv, :created}
      end
    end
  end

  def start_or_resume_conversation(attrs, opts) do
    with {:ok, conv} <- Conversations.start_conversation(attrs, opts), do: {:ok, conv, :created}
  end

  defp resume_channel(conv, agent, attrs, opts) do
    result =
      InferenceCredentials.with_source_lock(conv.user_id, fn ->
        Conversations.with_sandbox_lock(conv.sandbox_id, fn ->
          # Match turn admission and teardown: sandbox advisory lock, then
          # conversation row, then allowance. Taking the allowance first lets
          # narrowing hold the conversation while waiting on our allowance,
          # deadlocking the later label/source write. Codex reservation takes
          # the sandbox row only after this conversation lock too.
          current =
            Repo.one(
              from c in Conversation,
                where: c.id == ^conv.id and c.user_id == ^conv.user_id,
                lock: "FOR UPDATE",
                preload: [:sandbox, :agent, :vault, :agent_version]
            )

          # Ownership: `current` is the tenant-scoped `FOR UPDATE` read above.
          with %Conversation{} = current <- current || {:error, :not_found},
               :ok <-
                 if(current.sandbox_id == conv.sandbox_id,
                   do: :ok,
                   else: {:error, :provisioning}
                 ),
               :ok <- Conversations._unsafe_check_saved_execution_allowance(current.id),
               :ok <- check_sandbox_api_resume(current, attrs["sandbox_api_access"]),
               {:ok, source} <- Conversations.resolve_saved_inference(current, agent),
               {:ok, current, audit} <-
                 Conversations.resume_labels(current, attrs["labels"], opts),
               :ok <- InferenceBinding.reserve(current, source) do
            {:ok, {Repo.reload!(current), audit}}
          end
        end)
      end)

    with {:ok, {conv, audit}} <- result do
      Conversations.audit_labels(conv, audit, opts)
      {:ok, conv}
    end
  end

  defp check_sandbox_api_resume(_conv, nil), do: :ok
  defp check_sandbox_api_resume(%Conversation{sandbox_api_access: access}, access), do: :ok
  defp check_sandbox_api_resume(_conv, _access), do: {:error, :invalid_sandbox_api_access}

  # `true` or `"true"` — the ACP adapter sends a JSON boolean, a hand-built
  # request may send a string. Anything else is not a request.
  defp fresh_requested?(%{"fresh" => fresh}), do: fresh in [true, "true"]
  defp fresh_requested?(_attrs), do: false

  # The rotated-away conversation stops being the channel's binding. Nothing
  # else about it changes: if it is mid-turn it finishes, and it stays in the
  # user's list under its own id.
  defp unbind_channel(%Conversation{} = conv) do
    conv
    |> Ecto.Changeset.change(channel_id: nil)
    |> Repo.update()
  end

  # Inside admission's transaction, before the attachment's sandbox row lock.
  # Keep the selected conversation stable while replacing its binding; reject
  # a competing rotation that has already moved it.
  # Public for `Fountain.Conversations`, whose admission and
  # `fail_initial_start` call it until stages 7b/7c of #2175 move them here.
  def unbind_rotated_channel(attrs, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil ->
        :ok

      id ->
        case lock_rotation_conversation(id, attrs) do
          %Conversation{channel_id: channel} = conv when channel == attrs.channel_id ->
            with {:ok, _} <- unbind_channel(conv), do: :ok

          :busy ->
            {:error, rotation_conflict("the previous conversation is busy; retry the rotation")}

          _ ->
            {:error, rotation_conflict("binding changed; retry the rotation")}
        end
    end
  end

  # Worker startup and attachment prompt delivery run after admission commits.
  # Restore only while this replacement still owns the binding; a later
  # rotation must win over this failure. Keep the old -> new row lock order.
  # Public for `Fountain.Conversations`, whose admission and
  # `fail_initial_start` call it until stages 7b/7c of #2175 move them here.
  def restore_rotated_channel(conv, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil -> :ok
      id -> report_restore(conv, id, attempt_restore(conv, id))
    end
  end

  defp attempt_restore(conv, id) do
    Repo.transaction(fn ->
      with %Conversation{channel_id: nil} = previous <- lock_rotation_conversation(id, conv),
           %Conversation{channel_id: channel} = replacement
           when channel == conv.channel_id <- lock_rotation_conversation(conv.id, conv) do
        replacement |> Ecto.Changeset.change(channel_id: nil) |> Repo.update!()
        previous |> Ecto.Changeset.change(channel_id: channel) |> Repo.update!()
        :restored
      else
        # Contention on a row this compensation cannot wait for.
        :busy -> Repo.rollback(:busy)
        # A newer rotation already owns the binding, or the rows moved. That
        # rotation must win over this failure, so leaving them alone is right.
        _ -> :superseded
      end
    end)
  rescue
    e -> {:error, e}
  end

  defp report_restore(_conv, _id, {:ok, _outcome}), do: :ok

  # A compensation, not a rollback: nothing retries it and no caller can act on
  # it. Failing silently leaves a channel bound to nothing, which is the bug
  # this path exists to prevent wearing a different hat, so say so.
  defp report_restore(conv, id, other) do
    Logger.warning(
      "conv #{conv.id}: could not restore channel #{inspect(conv.channel_id)} to conv #{id} " <>
        "after a failed rotation: #{inspect(other)}"
    )

    :ok
  end

  defp rotation_conflict(message) do
    %Conversation{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:channel_id, message)
  end

  # How long a rotation may wait for the row it is replacing. On the fresh path
  # this runs inside `with_sandbox_reservation/3`, which holds the global fleet
  # advisory lock, and the row it wants is the one `_unsafe_create_turn_on_sandbox/3`
  # takes `FOR UPDATE` — so an unbounded wait would let one busy channel stall
  # provisioning for every tenant. Turn admission holds that row for a handful
  # of local queries, so this is orders of magnitude more than it ever
  # legitimately needs, and exceeding it means contention worth reporting
  # rather than waiting out.
  @rotation_lock_timeout_ms 250

  defp lock_rotation_conversation(id, attrs) do
    # Channel/ownership writes must serialize, but FK references may proceed.
    #
    # The bound is scoped to this read and handed straight back: `SET LOCAL`
    # lasts for the whole transaction, and admission goes on to insert rows
    # whose foreign keys take `KEY SHARE` on `users` — which a credit posting's
    # `FOR UPDATE` conflicts with. Leaving 250ms in force over those would turn
    # a slow billing write into an unrescued error on a path that has none.
    Repo.query!("SET LOCAL lock_timeout = '#{@rotation_lock_timeout_ms}ms'")

    conversation =
      from(c in Conversation,
        where: c.id == ^id and c.user_id == ^attrs.user_id and c.agent_id == ^attrs.agent_id,
        lock: "FOR NO KEY UPDATE"
      )
      |> where_vault(attrs.vault_id)
      |> where_environment(attrs.environment_id)
      |> Repo.one()

    Repo.query!("SET LOCAL lock_timeout = DEFAULT")
    conversation
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :lock_not_available do
        :busy
      else
        reraise(e, __STACKTRACE__)
      end
  end

  # The newest conversation still worth resuming for this binding. `vault_id`
  # is part of the key: two entries on one agent with different vaults are
  # different identities (#727) and must not share a conversation. So is the
  # environment override (#783): an identity that switches environments must
  # not resume a conversation provisioned from the old one.
  #
  # The sandbox is part of it too (#779): the 24 hour ceiling destroys a
  # sandbox while its conversation stays `idle`, and resuming that row wakes
  # onto a *fresh* machine with the workspace gone (#778 makes the turn work;
  # #936 is the memory it loses) inside a transcript that reads as continuous.
  # A channel is better served by a new conversation on a working machine, so
  # the binding follows the machine, not just the conversation row.
  # `suspended` is not in the list: that sandbox is parked, not gone, and its
  # disk wakes back up with the workspace on it.
  @doc """
  The conversation a channel binding resumes, resolved exactly as
  `start_or_resume_conversation/2` resolves it (same vault/environment/set selection),
  without opening one when there is none. For a request that must land on an
  existing conversation or fail — a tool answer on the bridge (#1202) — where
  opening a sandbox for a thread that has no parked call would be the wrong
  side effect. Tenant-scoped through `attrs["user_id"]`.
  """
  @spec channel_conversation(map()) :: Conversation.t() | nil
  def channel_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id),
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
         {:ok, set_id} <-
           Conversations.resolve_inference_credential_id(
             attrs["inference_credential_id"],
             user_id,
             agent
           ) do
      find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id, set_id)
    else
      _ -> nil
    end
  end

  def channel_conversation(_attrs), do: nil

  defp find_channel_conversation(user_id, agent_id, vault_id, env_id, channel_id, set_id) do
    from(c in Conversation,
      join: s in assoc(c, :sandbox),
      where:
        c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^channel_id and
          c.status not in ["terminated", "failed"] and
          s.status not in ["terminated", "failed"],
      order_by: [desc: c.inserted_at],
      limit: 1
    )
    |> where_vault(vault_id)
    |> where_environment(env_id)
    |> where_credential_set(set_id)
    |> Repo.one()
  end

  # An explicit set is part of a channel selection. An omitted set resumes
  # the channel's durable source, even after the account's default changes.
  defp where_credential_set(query, nil), do: query

  defp where_credential_set(query, id),
    do: from(c in query, where: c.inference_credential_id == ^id)

  defp where_vault(query, nil), do: from(c in query, where: is_nil(c.vault_id))
  defp where_vault(query, vault_id), do: from(c in query, where: c.vault_id == ^vault_id)

  defp where_environment(query, nil), do: from(c in query, where: is_nil(c.environment_id))
  defp where_environment(query, id), do: from(c in query, where: c.environment_id == ^id)
end
