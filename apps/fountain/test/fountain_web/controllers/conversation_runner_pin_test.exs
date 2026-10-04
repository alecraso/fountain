defmodule FountainWeb.ConversationRunnerPinTest do
  @moduledoc """
  `runner_id` on `POST /api/conversations` (arugula fork): the sandbox is
  minted for the runner the caller named, fetched under the caller's own
  `user_id`, because on this provider the sandbox name is the placement
  (ADR 0022) and `Connection.call/3` routes on it with no tenant argument.
  """

  # `runners_enabled` is global application env; see `Runners.PlacementTest`.
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Runners
  alias Fountain.Runners.Runner
  alias Managoat.Runner.FakeDaemon

  setup %{conn: conn} do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)
    %{conn: authed_with_key(conn, raw_key), user: user}
  end

  # `connected_at` is stamped by a real connection; the fake daemon does not
  # move it, so each runner gets an explicit, later one, making "most recently
  # connected" unambiguous.
  defp online_runner(user, name) do
    {:ok, runner} = Runners.register(user.id, %{"name" => name})
    at = DateTime.add(DateTime.utc_now(), System.unique_integer([:positive, :monotonic]), :second)
    Repo.update_all(from(r in Runner, where: r.id == ^runner.id), set: [connected_at: at])
    {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: name)
    on_exit(fn -> FakeDaemon.stop(daemon) end)
    runner
  end

  defp rows, do: {Repo.aggregate(Sandbox, :count), Repo.aggregate(Conversation, :count)}

  defp create(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/conversations", Jason.encode!(body))
  end

  test "places the sandbox on the named runner even when another connected later",
       %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    pinned = online_runner(user, "first")
    _newer = online_runner(user, "second")
    assert {:ok, %{id: picked}} = Runners.pick_runner(user.id)
    refute picked == pinned.id

    body =
      conn |> create(%{"agent_id" => agent.id, "runner_id" => pinned.id}) |> json_response(201)

    conv = Conversations._unsafe_get_conversation!(body["data"]["id"])
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert {:ok, pinned_id} = Runners.parse_sandbox_name(sandbox.machine_name)
    assert pinned_id == pinned.id
  end

  test "another account's online runner is a 404 and creates nothing", %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    _mine = online_runner(user, "mine")
    owner = insert_verified_user()
    theirs = online_runner(owner, "theirs")
    before = rows()

    body =
      conn |> create(%{"agent_id" => agent.id, "runner_id" => theirs.id}) |> json_response(404)

    assert body["error"] == "runner_not_found"
    assert rows() == before
  end

  test "a runner that does not exist answers like someone else's", %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    before = rows()

    body =
      conn
      |> create(%{"agent_id" => agent.id, "runner_id" => Ecto.UUID.generate()})
      |> json_response(404)

    assert body["error"] == "runner_not_found"
    assert rows() == before
  end

  test "the caller's offline runner is a 409 no_runner_online", %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    {:ok, offline} = Runners.register(user.id, %{"name" => "asleep"})
    _other_online = online_runner(user, "awake")
    before = rows()

    body =
      conn |> create(%{"agent_id" => agent.id, "runner_id" => offline.id}) |> json_response(409)

    assert body["error"] == "no_runner_online"
    assert rows() == before
  end

  test "runner_id on a non-runner agent is a 422", %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id)
    runner = online_runner(user, "mini")
    before = rows()

    body =
      conn |> create(%{"agent_id" => agent.id, "runner_id" => runner.id}) |> json_response(422)

    assert body["error"] == "runner_id_not_applicable"
    assert rows() == before
  end

  test "runner_id with sandbox_id is a 422", %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    runner = online_runner(user, "mini")
    first = conn |> create(%{"agent_id" => agent.id}) |> json_response(201)
    sandbox_id = Conversations._unsafe_get_conversation!(first["data"]["id"]).sandbox_id
    before = rows()

    body =
      conn
      |> create(%{"agent_id" => agent.id, "runner_id" => runner.id, "sandbox_id" => sandbox_id})
      |> json_response(422)

    assert body["error"] == "runner_id_with_sandbox"
    assert rows() == before
  end

  test "without runner_id the most recent runner is still picked", %{conn: conn, user: user} do
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    _first = online_runner(user, "first")
    _second = online_runner(user, "second")
    assert {:ok, %{id: picked}} = Runners.pick_runner(user.id)

    body = conn |> create(%{"agent_id" => agent.id}) |> json_response(201)

    sandbox =
      body["data"]["id"]
      |> Conversations._unsafe_get_conversation!()
      |> Map.fetch!(:sandbox_id)
      |> Conversations._unsafe_get_sandbox!()

    assert {:ok, ^picked} = Runners.parse_sandbox_name(sandbox.machine_name)
  end
end
