defmodule Fountain.Conversations.Wake do
  @moduledoc """
  The leaf half of waking a conversation: deciding what a stored sandbox can
  still do, and bringing a `ConversationServer` up on it.

  `Conversations.wake_conversation_for/3` is the only caller of the functions
  below. It establishes ownership before reaching here — the conversation is
  fetched tenant-scoped there, and every `sandbox_id` this module reads comes
  from that conversation's own row — so each function is documented as the
  leaf the wake door calls rather than re-justifying ownership on its own.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, Sandbox}

  # Probe the existing sandbox: if it's `ready` or `suspended` and sprites.dev
  # confirms the sprite still exists, we can reattach without provisioning a
  # new one. Otherwise, fall through to creating a fresh sandbox.
  #
  # The leaf `wake_conversation_for/3` calls first, once ownership is
  # established there; `sandbox_id` is the conversation's own row.
  def maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  def maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{reset_requested_at: at, status: status}
      when not is_nil(at) and status not in ["terminated", "failed"] ->
        {:error, :sandbox_reset_pending}

      %{status: status, machine_name: name} = sandbox
      when status in ["ready", "suspended"] and is_binary(name) ->
        probe_reusable_sandbox(sandbox, sandbox_id)

      # A provision is in flight — or was, in a BEAM that is gone. The
      # caller waits for the registry before deciding which (#800).
      %{status: status} when status in ["pending", "starting"] ->
        {:provisioning, sandbox_id}

      _ ->
        :create_new
    end
  end

  # The row's provider is sticky: a parked sandbox wakes on the backend that
  # holds its disk, never on whatever the instance default is by now. A row
  # whose (non-default) provider lost its credentials fails retryably — the
  # same protect-the-parked-disk reasoning as :sprite_probe_failed below;
  # falling through to :create_new would retire the row and orphan (or lose)
  # the parked sandbox. Re-adding the credentials restores wakes.
  #
  # A leaf of maybe_reuse_sandbox/1.
  def probe_reusable_sandbox(%{status: status, machine_name: name} = sandbox, sandbox_id) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    if provider != Fountain.SandboxProviders.default_provider() and
         not Fountain.SandboxProviders.enabled?(provider) do
      Logger.warning(
        "sandbox #{sandbox_id} is on disabled provider #{provider}; refusing to wake or retire"
      )

      {:error, {:sandbox_provider_disabled, provider}}
    else
      probe_sandbox(provider, name, status, sandbox_id)
    end
  end

  # A leaf of probe_reusable_sandbox/2.
  def probe_sandbox(provider, name, status, sandbox_id) do
    case Managoat.Sandbox.get(Managoat.Sandbox.build_handle(provider, name)) do
      {:ok, _info} ->
        {:reuse, sandbox_id}

      {:error, :not_found} ->
        :create_new

      # The machine behind a runner-backed sandbox is not connected (#834):
      # the same protect-the-disk rule as below, named, so the caller can say
      # "the machine is off" rather than "the provider is unreachable".
      {:error, {:unavailable, :runner_offline}} ->
        {:error, :runner_offline}

      {:error, reason} ->
        # A transient probe failure must not cost the disk: falling to
        # :create_new retires this row, and the reaper then destroys the
        # still-live sprite — with the agent's memory on it. Only a
        # definitive not-found gives up the sandbox; anything else fails the
        # wake retryably (503 + Retry-After at the API).
        #
        # This clause was `suspended`-only until #799: a `ready` row is the
        # same parked disk once its server is gone (a deploy, a crash, a
        # partition), and the 2026-08-18 incident showed the provider going
        # unreachable for 70 s with nine `ready` rows behind it.
        Logger.warning(
          "sprite probe failed for #{status} sandbox #{sandbox_id}: #{inspect(reason)}"
        )

        {:error, :sprite_probe_failed}
    end
  end

  # Waking a suspended sandbox turns a parked sprite back into compute, so it
  # re-runs the quota gate — under the same advisory lock as creation, with the
  # row re-read inside. Two concurrent wakes both probe `suspended`; the loser
  # re-reads the winner's `ready` flip and must not double-stamp the clock.
  # `exclude: sandbox_id` makes the check identical for both ("does the user
  # have capacity besides this sandbox"), so the loser is never spuriously
  # refused at the cap for a wake that added no concurrency.
  #
  # The second leaf `wake_conversation_for/3` calls, once ownership is
  # established there; `sandbox_id` is the conversation's own row.
  def wake_suspended_sandbox(user_id, sandbox_id) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: "suspended"} ->
        Fountain.Quotas.with_sandbox_reservation(user_id, [exclude: sandbox_id], fn ->
          case Conversations._unsafe_get_sandbox(sandbox_id) do
            %Sandbox{status: "suspended"} = sandbox ->
              resume_and_wake(sandbox)

            sandbox ->
              {:ok, sandbox}
          end
        end)

      sandbox ->
        {:ok, sandbox}
    end
  end

  # Resume BEFORE the row flips: if the provider's wake call fails, the row
  # stays `suspended` and the wake fails retryably — the parked disk is the
  # agent's memory, and a row marked ready over a still-parked backend would
  # strand it. For Sprites resume is a probe (waking is a side effect of the
  # next exec); for pause/stop providers it is the call that restarts the
  # sandbox.
  #
  # Runs under `wake_suspended_sandbox/2`'s reservation lock (see the
  # lock-order note there); a leaf of it, not called directly by the wake
  # door.
  def resume_and_wake(sandbox) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    case Managoat.Sandbox.resume(handle) do
      {:ok, _handle} ->
        Conversations.update_sandbox(sandbox, %{
          status: "ready",
          last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:error, reason} ->
        Logger.warning(
          "resume failed for suspended sandbox #{sandbox.id} (#{inspect(reason)}); " <>
            "leaving it parked"
        )

        {:error, :sandbox_resume_failed}
    end
  end

  # The child spec deliberately carries no prompt.
  #
  # Horde redistributes children when cluster membership changes — which every
  # deploy does — and restarts each one from its *stored child spec*. A prompt
  # baked into that spec is therefore replayed on every rebalance, silently
  # re-running the user's last message against the agent. Production
  # accumulated 38 turns from 2 distinct prompts on one conversation this way,
  # one duplicate per rollout, and the agent on the other end spent several
  # turns pointing out it was being asked the same thing repeatedly.
  #
  # So the prompt is delivered out of band, after the server exists. A cast is
  # queued behind handle_continue(:provision), so it is processed once
  # provisioning finishes; if provisioning fails the server stops and the cast
  # dies with it, which is the right outcome — no turn on a failed provision.
  #
  # The third leaf `wake_conversation_for/3` calls on the reuse path; also
  # called from `Conversations.create_fresh_sandbox_and_start/4` on the
  # fresh-sandbox path (stage 3). `conv` is the caller's own tenant-scoped
  # row, so the re-fetch below reads under that same ownership.
  def start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt) do
    with {:ok, pid} <-
           Horde.DynamicSupervisor.start_child(
             Fountain.ConversationSupervisor,
             {ConversationServer,
              [
                conversation_id: conv.id,
                sandbox_id: sandbox_id,
                runtime_module: runtime_module
              ]}
           ) do
      if is_binary(initial_prompt) and initial_prompt != "" do
        ConversationServer.queue_initial_prompt(pid, initial_prompt)
      end

      # ownership: conv is the caller's own tenant-scoped row (see the
      # function doc above); this re-fetch reads under that same ownership.
      {:ok, Conversations._unsafe_get_conversation!(conv.id)}
    end
  end
end
