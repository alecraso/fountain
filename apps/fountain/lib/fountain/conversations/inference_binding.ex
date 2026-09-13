defmodule Fountain.Conversations.InferenceBinding do
  @moduledoc """
  Durable admission for the shared Codex auth location.

  Every preparing or resumable conversation reserves its resolved identity and
  revision. The sandbox row serializes contenders before any auth-file write.
  Legacy peers without a binding are incompatible. The machine retains its
  auth binding through conversation termination and deletion: a detached runtime
  may survive its actor, so only a new sandbox can change that binding.
  """
  import Ecto.Query
  alias Fountain.{InferenceCredentials, Repo}
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.InferenceCredentials.Source

  @configuration_fields ~w(configuration_revision sandbox_id agent_id agent_version_id runtime environment_id vault_id)a

  @doc """
  Re-read a caller's configuration under the admission locks before resolving
  or reserving inference. The callback may access the database, never a provider.
  A stale actor must reload or stop without failing the newer configuration.
  """
  def with_current(conv, fun) do
    InferenceCredentials.with_source_lock(conv.user_id, fn ->
      if conv.sandbox_id do
        # Match turn admission, reapply and teardown before any row lock.
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          4316,
          :erlang.phash2(conv.sandbox_id)
        ])
      end

      current =
        Repo.one(
          from c in Conversation,
            where: c.id == ^conv.id and c.user_id == ^conv.user_id,
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          {:error, :configuration_changed}

        Map.take(current, @configuration_fields) != Map.take(conv, @configuration_fields) ->
          {:error, :configuration_changed}

        true ->
          fun.(current)
      end
    end)
  end

  def reserve(conv, %Source{} = source) do
    with_current(conv, fn current ->
      with :ok <- current_source(current, source),
           :ok <- InferenceCredentials.validate_source(current.user_id, source),
           :ok <- Fountain.PlatformInference.gate_source(source),
           :ok <- compatible_machine(current, source) do
        case current
             |> Ecto.Changeset.change(inference_source: Source.dump(source))
             |> Repo.update() do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  # A nil snapshot does not authorize replacing a binding committed while the
  # actor was doing provider I/O. Initial legacy binding remains supported;
  # an idempotent reservation must match the persisted source in full.
  defp current_source(%{inference_source: nil}, _source), do: :ok

  defp current_source(current, source) do
    if current.inference_source == Source.dump(source),
      do: :ok,
      else: {:error, :inference_source_changed}
  end

  defp compatible_machine(%{runtime: runtime}, _) when runtime != "codex", do: :ok

  defp compatible_machine(conv, source) do
    sandbox =
      Repo.one(
        from s in Sandbox,
          where: s.id == ^conv.sandbox_id and s.user_id == ^conv.user_id,
          lock: "FOR NO KEY UPDATE"
      )

    if sandbox do
      peers =
        Repo.all(
          from c in Conversation,
            where: c.sandbox_id == ^sandbox.id and c.id != ^conv.id and c.runtime == "codex",
            select: c.inference_source
        )

      stored = sandbox.codex_inference_source

      fresh? = sandbox.status in ["pending", "starting"]

      if ((is_nil(stored) and fresh?) or compatible?(stored, Source.dump(source))) and
           Enum.all?(peers, &compatible?(&1, Source.dump(source))) do
        sandbox
        |> Ecto.Changeset.change(codex_inference_source: Source.dump(source))
        |> Repo.update!()

        :ok
      else
        {:error, :codex_inference_conflict}
      end
    else
      {:error, :sandbox_not_found}
    end
  end

  defp compatible?(nil, _), do: false

  defp compatible?(left, right),
    do: Map.take(left, ~w(kind identity revision)) == Map.take(right, ~w(kind identity revision))
end
