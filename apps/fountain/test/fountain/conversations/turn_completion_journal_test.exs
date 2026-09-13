defmodule Fountain.Conversations.TurnCompletionJournalTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{ExecutionGuard, TurnMachine}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    turn = insert_turn(conv, status: "running", started_at: DateTime.utc_now())

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    %{conv: conv, turn: turn, execution: execution, sandbox: sandbox}
  end

  defp bind(c) do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)

    {:ok, _} =
      ExecutionGuard._unsafe_bind_identity(
        c.execution.id,
        c.execution.connection_id,
        "command-2054"
      )
  end

  defp finish(c),
    do:
      TurnMachine.finish(
        %TurnMachine{conversation_id: c.conv.id, sandbox_id: c.sandbox.id, row: c.turn},
        "completed",
        %{},
        %{}
      )

  defp stages(c),
    do: Conversations._unsafe_list_log_events(c.conv.id) |> Enum.filter(&(&1.stage == "turn"))

  test "success retires the journal in the same commit as its turn and parent", c do
    bind(c)

    insert_log_event(c.conv,
      turn_id: c.turn.id,
      stream: "acp",
      data:
        ~s({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"reply"}}}})
    )

    assert {:ok, ended} =
             Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed", exit_code: 0)

    assert ended.status == "completed"
    assert ended.reply_text == "reply"
    assert ended.exit_code == 0
    assert Repo.reload!(c.execution).state == "ready"
    assert Repo.reload!(c.conv).status == "idle"
    assert {:error, :execution_fenced} = ExecutionGuard._unsafe_admission_gate(c.conv.id)
  end

  test "an expired completion preserves the deadline failure and announces it once", c do
    bind(c)

    c.execution
    |> Ecto.Changeset.change(deadline_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    finish(c)

    assert %{status: "failed", limit_reason: "wall_time_limit", exit_code: nil} =
             Repo.reload!(c.turn)

    assert Repo.reload!(c.execution).state == "ready"
    assert Repo.reload!(c.conv).status == "idle"
    assert [%{state: "failed"}] = stages(c)
    finish(c)
    assert [%{state: "failed"}] = stages(c)
  end

  test "successful waiting completion preserves its detached request metadata", c do
    bind(c)
    pending = %{"request_id" => "approval-2054", "tool" => "Bash"}
    c.turn |> Ecto.Changeset.change(waiting: true, pending_permission: pending) |> Repo.update!()

    finish(c)

    assert %{status: "completed", waiting: true, pending_permission: ^pending} =
             Repo.reload!(c.turn)

    assert Repo.reload!(c.conv).status == "idle"
    assert [%{state: "done", data: data}] = stages(c)
    assert %{"waiting" => true, "waiting_request_id" => "approval-2054"} = Jason.decode!(data)
  end

  test "a submitted spawn without identity fails and keeps its remote fence", c do
    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(c.execution.id)

    assert {:ok, ended} =
             Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed", exit_code: 0)

    assert ended.status == "failed"
    assert ended.exit_code == nil

    assert %{state: "awaiting_identity", last_error: "spawn_unconfirmed"} =
             Repo.reload!(c.execution)

    assert Repo.reload!(c.conv).status == "idle"
  end

  test "success before any command started rolls back every completion write", c do
    original_conv = Repo.reload!(c.conv)

    assert {:error, :execution_not_started} =
             Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed")

    assert Repo.reload!(c.turn) == c.turn
    assert Repo.reload!(c.execution) == c.execution
    assert Repo.reload!(c.conv) == original_conv
    assert stages(c) == []
  end

  for journal? <- [false, true] do
    test "an already-ended latest turn releases its parent with journal=#{journal?}", c do
      if unquote(journal?) do
        bind(c)
        {:ok, _} = ExecutionGuard._unsafe_complete(c.execution.id, "interrupted")
      else
        Repo.delete!(c.execution)

        c.turn
        |> Ecto.Changeset.change(
          status: "interrupted",
          ended_at: DateTime.truncate(DateTime.utc_now(), :second)
        )
        |> Repo.update!()
      end

      ended = Repo.reload!(c.turn)
      assert :noop = Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed")
      assert Repo.reload!(c.turn) == ended
      assert Repo.reload!(c.conv).status == "idle"
      assert stages(c) == []
    end
  end

  test "a rebound actor cannot retire its journal or write its reply", c do
    bind(c)
    replacement = insert_sandbox(user_id: c.conv.user_id, status: "ready")
    c.conv |> Ecto.Changeset.change(sandbox_id: replacement.id) |> Repo.update!()
    assert :noop = Conversations._unsafe_complete_turn(c.turn, c.sandbox.id, "completed")
    assert Repo.reload!(c.turn).status == "running"
    assert Repo.reload!(c.execution).state == "active"
    assert Repo.reload!(c.conv).status == "running"
  end
end
