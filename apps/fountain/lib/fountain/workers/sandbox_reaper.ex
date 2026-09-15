defmodule Fountain.Workers.SandboxReaper do
  @moduledoc """
  Reconciles the `sandboxes` table against what actually exists at sprites.dev.

  ## What leaks, and how

  Both destroy call sites in `ConversationServer` discard the result —
  `_ = Managoat.Sandbox.destroy(handle)` — and then mark the row `terminated` or
  `failed` regardless. So any destroy that fails for a transient reason leaves a
  sprite alive with a database row that says it is gone, and nothing ever looks
  again. This does not need a hard BEAM crash; the ordinary path is enough.

  Measured against production when this was written: 114 sprites existed at
  sprites.dev, 7 of them with a terminal sandbox row. The rest of the drift is
  historical (102 sprites with no row at all, from the pre-rename `aod-*` era)
  and 443 rows whose sprite is already gone.

  The other half is quota. `Fountain.Quotas` counts `pending`, `starting` and
  `ready` toward a tenant's concurrent-sandbox cap, deliberately — a sprite
  bills from the moment provisioning starts. A row stuck in `pending` because
  the BEAM died mid-provision therefore consumes cap forever, and a
  default-limit tenant with a few of those cannot start a conversation at all,
  with no self-serve way out.

  ## Three passes, in descending order of confidence

  1. **Release stuck rows.** `pending`/`starting` past the grace period with no
     live `ConversationServer` become `failed`. This frees quota and is safe:
     the row already cannot be used for anything.

  2. **Destroy sprites we know are dead.** A sandbox row in a terminal state
     whose sprite still exists at sprites.dev. Unambiguously ours,
     unambiguously finished.

  3. **Count sprites we do not recognise, and touch nothing.** Reported as a
     log line and a telemetry measurement.

  Pass 3 is deliberately inert. A sprite with no row is not proof of a leak: the
  same `SPRITES_TOKEN` may be in a developer's shell or a staging instance, and
  a sprite created seconds ago may simply not have committed its row yet.
  Production currently holds a `jake-*` sprite that is exactly this case.
  Destroying by absence-of-evidence would eventually delete someone's live work,
  and unlike a missed sprite that mistake cannot be undone. Cleaning up the
  legacy `aod-*` sprites is a one-off an operator can do by hand, having looked
  at the list.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Lifecycle, Sandbox, Turn}
  alias Fountain.Repo

  # Long enough to clear the slowest legitimate provision: package installs get
  # 300s per command and a clone gets 600s, and several can run in sequence.
  # Being late to release a stuck row costs a little quota; being early kills a
  # sandbox that was still starting.
  @stuck_after_minutes 60

  # A cap per run, so a large backlog drains over several hours instead of
  # firing hundreds of destroy calls at sprites.dev in one burst.
  @destroy_limit 25

  @terminal_statuses ~w(terminated failed)
  @active_statuses ~w(pending starting)

  @impl Oban.Worker
  def perform(_job) do
    released = release_stuck_sandboxes()
    {parked, expired} = sweep_abandoned_sandboxes()

    listings = list_by_provider()
    ok_listings = for {p, {:ok, names}} <- listings, into: %{}, do: {p, names}
    destroyed = destroy_dead_sprites(ok_listings)
    untracked = report_untracked(ok_listings)

    live = ok_listings |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum()

    Logger.info(
      "reaper: released=#{released} parked=#{parked} expired=#{expired} " <>
        "destroyed=#{destroyed} untracked=#{untracked} live=#{live}"
    )

    result =
      case for {p, {:error, reason}} <- listings, do: {p, reason} do
        [] ->
          :ok

        [{provider, reason} | _] = failures ->
          # Every pass that could run already did — per-provider isolation
          # means one backend's listing failure does not stop another's
          # destroys. Returning an error lets Oban retry the rest.
          Enum.each(failures, fn {p, r} ->
            Logger.warning("reaper: could not list #{p} sandboxes: #{inspect(r)}")
          end)

          _ = provider
          {:error, reason}
      end

    # `parked` is its own measurement: parks are reversible bookkeeping, and
    # folding them into `expired` would silently change what that metric means.
    :telemetry.execute(
      [:fountain, :reaper, :run],
      %{released: released, parked: parked, expired: expired},
      %{}
    )

    result
  end

  # ── pass 1: rows stuck mid-provision ──────────────────────────────────────

  @doc false
  def release_stuck_sandboxes do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stuck_after_minutes * 60, :second)

    Sandbox
    |> where(
      [s],
      s.status in ^@active_statuses and is_nil(s.reset_requested_at) and s.updated_at < ^cutoff
    )
    |> Repo.all()
    |> Repo.preload(:conversations)
    |> Enum.filter(&stuck_eligible?(&1, cutoff))
    |> Enum.count(&(release_one_stuck(&1, cutoff) == :released))
  end

  # The scan above and this recheck must apply the exact same test, or a row
  # that stopped being a stuck-provision row between the two (turn admission
  # won the sandbox's advisory lock and finished provisioning it) would still
  # get marked `failed` once the reaper's own turn at the lock comes up.
  defp stuck_eligible?(%Sandbox{} = sandbox, cutoff) do
    sandbox.status in @active_statuses and is_nil(sandbox.reset_requested_at) and
      sandbox.updated_at < cutoff and not Lifecycle.any_server_alive?(sandbox)
  end

  defp release_one_stuck(sandbox, cutoff) do
    was = sandbox.status

    {:ok, result} =
      Conversations.with_sandbox_lock(sandbox.id, fn ->
        # ownership: sandbox is our own scan's candidate above; a system
        # sweep re-reads it fresh under the lock because admission can win
        # the race to finish provisioning it between that scan and this lock.
        fresh = reload_with_conversations(sandbox.id)

        if fresh && stuck_eligible?(fresh, cutoff) do
          {:ok, updated} =
            Conversations.update_sandbox(fresh, %{
              status: "failed",
              terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          {:ok, {:released, updated}}
        else
          {:ok, :skipped}
        end
      end)

    case result do
      {:released, updated} ->
        Logger.info(
          "reaper: released stuck sandbox #{updated.id} (#{updated.machine_name}) " <>
            "after #{@stuck_after_minutes}m in #{was}"
        )

        record_reap(updated, "sandbox.released_stuck", %{
          "previous_status" => was,
          "stuck_after_minutes" => @stuck_after_minutes
        })

        :released

      :skipped ->
        Logger.info(
          "reaper: sandbox #{sandbox.id} became active under the lock; left alone"
        )

        :skipped
    end
  end

  # A fresh, `:conversations`-preloaded read of a sandbox this module already
  # holds a stale copy of, taken under `Conversations.with_sandbox_lock/2` so
  # every recheck below sees exactly what a concurrent admission committed
  # (or did not) while racing for that same lock. `nil` when the row is gone.
  defp reload_with_conversations(sandbox_id) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil -> nil
      sandbox -> Repo.preload(sandbox, :conversations)
    end
  end

  # A live ConversationServer means provisioning is still in flight somewhere in
  # the cluster, however long it has taken. Horde's registry is cluster-wide, so
  # this is not just a local check — `Lifecycle.any_server_alive?/1` is the one
  # scan for it (#2255 decision 2).
  # A sandbox the tenant did not stop, ending for a reason only the reaper
  # knows. Attributed to the worker so "my agent's sandbox vanished" has an
  # answer in the tenant's own trail rather than only in the server log —
  # `admin.sandbox.reaped` covered the admin-clicked path and nothing covered
  # this one (#551).
  defp record_reap(%Sandbox{} = sandbox, action, metadata) do
    Fountain.Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: "system:sandbox_reaper",
      metadata:
        metadata
        |> Map.put("sprite_name", sandbox.machine_name)
        |> Map.put("provider", sandbox.provider)
    })
  end

  # ── pass 1b: ready sandboxes nobody is holding ────────────────────────────

  # A `ready` row whose server died mid-wake looks identical to an abandoned
  # one until the new server registers in Horde — whose registry is an async
  # CRDT, so `server_alive?/1` can briefly miss a live server on another node.
  # The wake path touches `updated_at` when it flips `suspended → ready`, so a
  # grace period on `updated_at` makes a just-woken row untouchable for far
  # longer than registry propagation takes.
  @abandoned_grace_minutes 15

  @doc """
  Sweeps `ready` sandboxes with no live server past a lifetime bound: past the
  idle bound they are parked to `suspended` (the sprite stays, scaled to zero,
  and the next prompt reattaches — decisions/0017); past the max-lifetime
  ceiling they are terminated, and pass 2 destroys the sprite this same run.

  This is the half of #167 that the ConversationServer cannot do. The server
  enforces its own bounds while it is alive, but a sandbox whose server
  died — a crash, a node that left the cluster, a deploy that happened to land
  between the rehydrator's scan and a reattach — has nothing watching it. The
  83-day-old sandbox in production was exactly that: `ready`, no server, alive
  since 2026-05-10.

  `suspended` rows deliberately match no pass: that is the durable resting
  state, aged out by nothing (decisions/0017).

  Activity includes turn insertion, start, completion and the last wake rather
  than `sandboxes.updated_at` or `conversations.updated_at`, both of which get
  touched by bookkeeping the user had nothing to do with — the rehydrator moves
  `conversations.updated_at` on every boot, which would make an abandoned
  conversation look freshly active after each deploy.

  Returns `{parked, expired}`.
  """
  def sweep_abandoned_sandboxes do
    idle = Lifecycle.idle_timeout_seconds()
    max_lifetime = Lifecycle.max_lifetime_seconds()

    if is_nil(idle) and is_nil(max_lifetime) do
      {0, 0}
    else
      now = DateTime.utc_now()
      grace_cutoff = DateTime.add(now, -@abandoned_grace_minutes * 60, :second)

      verdicts =
        Sandbox
        |> where(
          [s],
          s.status == "ready" and is_nil(s.reset_requested_at) and s.updated_at < ^grace_cutoff
        )
        |> Repo.all()
        |> Repo.preload(:conversations)
        |> Enum.reject(&Lifecycle.any_server_alive?/1)
        |> Enum.map(&{&1, check_bounds(&1, now)})

      {parked, expired} =
        Enum.reduce(verdicts, {0, 0}, fn
          {sandbox, {:expired, :idle}}, {p, e} ->
            case idle_sweep(sandbox) do
              :parked -> {p + 1, e}
              :expired -> {p, e + 1}
              :skipped -> {p, e}
            end

          {sandbox, {:expired, :max_lifetime}}, {p, e} ->
            case expire(sandbox, "past max lifetime", {:expired, :max_lifetime}) do
              :expired -> {p, e + 1}
              :skipped -> {p, e}
            end

          {_sandbox, :ok}, acc ->
            acc
        end)

      {parked, expired}
    end
  end

  # Same clock as ConversationServer.sandbox_clock_start/1: the max-lifetime
  # ceiling measures a continuous run, restarting on a wake from `suspended`.
  defp check_bounds(sandbox, now) do
    started_at = sandbox.last_resumed_at || sandbox.inserted_at
    Lifecycle.check(started_at, last_activity_at(sandbox), false, now)
  end

  # A queued or long-running turn can finish long after insertion. Waking
  # without a new turn is also activity; bookkeeping updates are not.
  defp last_activity_at(%Sandbox{} = sandbox) do
    %{inserted_at: inserted_at, last_resumed_at: resumed_at, conversations: convs} = sandbox
    conv_ids = Enum.map(convs, & &1.id)

    {inserted, started, ended} =
      Turn
      |> where([t], t.conversation_id in ^conv_ids)
      |> select([t], {max(t.inserted_at), max(t.started_at), max(t.ended_at)})
      |> Repo.one()

    [inserted_at, resumed_at, inserted, started, ended]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime)
  end

  # The scan (`Enum.reject(&Lifecycle.any_server_alive?/1)`, `check_bounds/2`
  # above) and this recheck must apply the exact same test for the same
  # reason `stuck_eligible?/2` does: admission can win the sandbox's advisory
  # lock and commit a running turn after the scan and before the reaper's
  # own turn at that lock. `expected_verdict` pins the recheck to the bound
  # the caller classified this candidate under, so a row that has since
  # moved between bounds (idle vs. max-lifetime) is left for the next run
  # rather than acted on under a verdict that is no longer current either.
  defp ready_abandoned?(%Sandbox{} = sandbox, expected_verdict, now) do
    sandbox.status == "ready" and is_nil(sandbox.reset_requested_at) and
      not Lifecycle.any_server_alive?(sandbox) and check_bounds(sandbox, now) == expected_verdict
  end

  # Idle with no server: park where the provider can preserve the disk,
  # expire where it cannot — the same Lifecycle.idle_action/1 decision the
  # ConversationServer applies, and the same degradation when the explicit
  # suspend call fails (an unparked sandbox keeps billing). `idle_action/1`
  # is a pure provider-capability check, safe to ask before the lock.
  defp idle_sweep(sandbox) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    case Lifecycle.idle_action(provider) do
      :destroy ->
        case expire(sandbox, "idle on a provider without suspend", {:expired, :idle}) do
          :expired -> :expired
          :skipped -> :skipped
        end

      :suspend ->
        case claim_for_suspend(sandbox) do
          {:claimed, claimed} -> suspend_claimed(claimed, provider)
          :skipped -> log_became_active(sandbox.id)
        end
    end
  end

  # The claim: revalidate fresh under the lock and, only if still eligible,
  # write `suspended` right there. No provider I/O runs under the lock (the
  # rule every `with_sandbox_lock/2` caller follows) — but the row write
  # itself is the fence once it commits: `suspended` is a state admission's
  # `update_sandbox` guards do not refuse (a legitimate later wake reattaches
  # to it, same as any ordinary park), while an admission racing for this
  # same lock either already committed before we got here (so the fresh read
  # sees its live server or turn and this returns `:skipped`) or is still
  # queued behind us (and proceeds against the `suspended` row we leave,
  # which is exactly what a wake after a park looks like).
  defp claim_for_suspend(sandbox) do
    now = DateTime.utc_now()

    {:ok, result} =
      Conversations.with_sandbox_lock(sandbox.id, fn ->
        fresh = reload_with_conversations(sandbox.id)

        if fresh && ready_abandoned?(fresh, {:expired, :idle}, now) do
          {:ok, updated} = Conversations.update_sandbox(fresh, %{status: "suspended"})
          {:ok, {:claimed, updated}}
        else
          {:ok, :skipped}
        end
      end)

    result
  end

  # Provider I/O for a sandbox this run already claimed as `suspended` above
  # — never inside the lock. A checkpoint or suspend failure cannot revive
  # the row (`suspended` already committed); it can only leave the sprite
  # itself out of step with a row that says it is parked, which the explicit
  # fallback below corrects the same way the pre-lock code did.
  defp suspend_claimed(claimed, provider) do
    Fountain.Conversations.HomeCheckpoint.on_park(claimed)

    case Managoat.Sandbox.suspend(Managoat.Sandbox.build_handle(provider, claimed.machine_name)) do
      :ok ->
        Logger.info(
          "reaper: parked idle sandbox #{claimed.id} (#{claimed.machine_name}) — " <>
            "ready with no live server past the idle bound"
        )

        record_reap(claimed, "sandbox.suspended", %{"reason" => "idle with no live server"})
        :parked

      {:error, reason} ->
        Logger.warning(
          "reaper: suspend call failed for #{claimed.machine_name} (#{inspect(reason)}); " <>
            "expiring instead"
        )

        expire_after_failed_suspend(claimed, "idle; suspend call failed")
    end
  end

  # The provider suspend call above failed, so this run's own `suspended`
  # claim is corrected to `terminated` (an unparked sandbox keeps billing) —
  # unless a legitimate wake already moved the row on while that provider
  # call was in flight, in which case there is nothing to correct and the
  # now-active sandbox is left alone.
  defp expire_after_failed_suspend(claimed, reason) do
    case expire_locked(claimed.id, &(&1.status == "suspended")) do
      {:expired, updated} ->
        finish_expire(updated, reason)
        :expired

      :skipped ->
        log_became_active(claimed.id)
    end
  end

  defp expire(sandbox, reason, expected_verdict) do
    now = DateTime.utc_now()

    case expire_locked(sandbox.id, &ready_abandoned?(&1, expected_verdict, now)) do
      {:expired, updated} ->
        finish_expire(updated, reason)
        :expired

      :skipped ->
        log_became_active(sandbox.id)
    end
  end

  defp expire_locked(sandbox_id, eligible?) do
    {:ok, result} =
      Conversations.with_sandbox_lock(sandbox_id, fn ->
        fresh = reload_with_conversations(sandbox_id)

        if fresh && eligible?.(fresh) do
          {:ok, updated} =
            Conversations.update_sandbox(fresh, %{
              status: "terminated",
              terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          {:ok, {:expired, updated}}
        else
          {:ok, :skipped}
        end
      end)

    result
  end

  defp finish_expire(sandbox, reason) do
    Logger.info(
      "reaper: expired abandoned sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "ready with no live server, #{reason}"
    )

    record_reap(sandbox, "sandbox.expired", %{"reason" => reason})

    # The conversation is deliberately left alone. It stays resumable, and the
    # next prompt provisions a fresh sandbox (the runtime session on the
    # destroyed disk is lost — the price of the ceiling, see decisions/0017).
    # The sandbox itself is destroyed by pass 2 on this same run, now that the
    # row is terminal.
    sandbox
  end

  defp log_became_active(sandbox_id) do
    Logger.info("reaper: sandbox #{sandbox_id} became active under the lock; left alone")
    :skipped
  end

  # ── pass 2: terminal rows whose sprite is still there ─────────────────────

  defp destroy_dead_sprites(live_by_provider) do
    Sandbox
    |> where([s], s.status in ^@terminal_statuses)
    |> select([s], {s.id, s.machine_name, s.provider})
    |> Repo.all()
    |> Enum.filter(fn {_id, name, provider} ->
      case Map.fetch(live_by_provider, provider_atom(provider)) do
        # Rows on a provider whose listing failed (or that is disabled) are
        # skipped, not destroyed — the next run with credentials converges.
        {:ok, live_names} -> MapSet.member?(live_names, name)
        :error -> false
      end
    end)
    |> Enum.take(@destroy_limit)
    |> Enum.count(fn {id, name, provider} -> destroy(id, name, provider_atom(provider)) end)
  end

  defp provider_atom(provider), do: Conversations.sandbox_provider_atom(%{provider: provider})

  defp destroy(sandbox_id, machine_name, provider) do
    # build_handle/2 is pure — we already know the sandbox exists (it came
    # out of the listing), so there is nothing to look up first.
    case Managoat.Sandbox.destroy(Managoat.Sandbox.build_handle(provider, machine_name)) do
      :ok ->
        Logger.info("reaper: destroyed leaked sprite #{machine_name} (sandbox #{sandbox_id})")
        true

      {:error, reason} ->
        # Left for the next run rather than retried here; the row stays terminal
        # either way, so nothing is lost by being slow about it.
        Logger.warning("reaper: destroy failed for #{machine_name}: #{inspect(reason)}")
        false
    end
  end

  # ── pass 3: sprites with no row — counted, never touched ──────────────────

  @doc false
  def report_untracked(live_by_provider) do
    Enum.reduce(live_by_provider, 0, fn {provider, live_names}, total ->
      known =
        Sandbox
        |> where([s], s.provider == ^Atom.to_string(provider))
        |> select([s], s.machine_name)
        |> Repo.all()
        |> MapSet.new()

      untracked = MapSet.difference(live_names, known)
      count = MapSet.size(untracked)

      if count > 0 do
        sample = untracked |> Enum.sort() |> Enum.take(10) |> Enum.join(", ")

        Logger.info(
          "reaper: #{count} #{provider} sandbox(es) have no sandbox row and were " <>
            "left alone (sample: #{sample})"
        )
      end

      :telemetry.execute([:fountain, :reaper, :untracked], %{count: count}, %{
        provider: provider
      })

      total + count
    end)
  end

  # ── sprites.dev ───────────────────────────────────────────────────────────

  # One listing per provider, isolated: one backend being down must not stop
  # another's reconciliation. Sprites is always attempted (the historical
  # default may hold rows even when its credential was pulled); other
  # providers only when enabled. Pagination is the adapter's problem — a
  # first-page-only listing looks complete, which for a function that decides
  # what to delete is the worst possible shape of wrong, so adapters return
  # {:error, :truncated} rather than a partial view.
  defp list_by_provider do
    [:sprites | Fountain.SandboxProviders.enabled_providers()]
    |> Enum.uniq()
    |> Map.new(fn provider -> {provider, safe_list(provider)} end)
  end

  defp safe_list(provider) do
    Managoat.Sandbox.list_all_names(provider)
  rescue
    e -> {:error, e}
  end
end
