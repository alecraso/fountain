defmodule FountainWeb.RunnerKeyTest do
  # Not async: the registration tests turn `:runners_enabled` on, which is
  # global application env.
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Fountain.DataCase, only: [errors_on: 1]

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey
  alias Fountain.Repo
  alias Fountain.Runners
  alias Managoat.Runner.FakeDaemon

  setup %{conn: conn} do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fountain, :runners_enabled),
        else: Application.put_env(:fountain, :runners_enabled, previous)
    end)

    user = insert_verified_user()
    {_record, full_key} = insert_api_key(user)

    {record, runner_key} =
      insert_api_key(user, "runner:mini", scopes: ["runner"], runner_name: "mini")

    %{
      conn: conn,
      user: user,
      full_key: full_key,
      runner_key: runner_key,
      runner_record: record
    }
  end

  defp as(conn, key), do: authed_with_key(conn, key)

  # Every route that runs the `:api` pipeline, read off the router so a route
  # added tomorrow is in the sample without anyone editing this file. The
  # router's own route list does not say which pipelines a route pipes through,
  # so `route_info/4` is asked per route.
  defp api_routes do
    for route <- FountainWeb.Router.__routes__(),
        String.starts_with?(route.path, "/api"),
        verb = if(route.verb == :*, do: "GET", else: route.verb |> to_string() |> String.upcase()),
        path = Regex.replace(~r/[:*][a-z_]+/, route.path, "x"),
        %{pipe_through: pipes} <- [Phoenix.Router.route_info(FountainWeb.Router, verb, path, "")],
        :api in pipes do
      %{verb: verb, path: path, pipes: pipes}
    end
  end

  describe "default-deny" do
    test "a runner key is refused on every /api route but the runner socket", %{
      conn: conn,
      runner_key: runner_key
    } do
      routes = Enum.reject(api_routes(), &(&1.verb == "GET" and &1.path == "/api/runners/ws"))

      # The sample must reach every scope block of the router, not a handful
      # of routes someone remembered: a pipeline combination with no route
      # here is a block this test silently stopped covering.
      pipelines = routes |> Enum.map(& &1.pipes) |> Enum.uniq()

      for expected <- [
            [:accepts_json, :api],
            [:accepts_json, :api, :require_full_scope],
            [:accepts_json, :api, :require_full_scope, :require_admin_api],
            [:accepts_json, :api, :require_key_management],
            [:api]
          ] do
        assert expected in pipelines, "no sampled route pipes through #{inspect(expected)}"
      end

      assert length(routes) > 100

      refused =
        for %{verb: verb, path: path} <- routes do
          resp = conn |> as(runner_key) |> dispatch(@endpoint, verb, path)
          {verb, path, resp.status, resp.resp_body}
        end

      leaks =
        Enum.reject(refused, fn {_, _, status, body} -> status == 403 and insufficient?(body) end)

      assert leaks == [],
             "a runner key got through on: " <>
               inspect(Enum.map(leaks, fn {v, p, s, _} -> {v, p, s} end))
    end

    test "the sweep is not vacuous: a full key is not refused as insufficient scope on them", %{
      conn: conn,
      full_key: full_key
    } do
      # Guards the sweep against passing because every route 403s for some
      # other reason (a bad path, a broken pipeline).
      reached =
        for %{verb: "GET", path: path, pipes: pipes} <- api_routes(),
            :require_full_scope in pipes or :accepts_json in pipes,
            # A literal "x" is not an id; those routes crash on a bad uuid.
            not String.contains?(path, "/x"),
            path != "/api/runners/ws" do
          conn |> as(full_key) |> get(path)
        end

      assert length(reached) > 20
      refute Enum.any?(reached, &(&1.status == 403 and insufficient?(&1.resp_body)))
    end

    test "the conversation, prompt and /me surfaces a sprite key may use are refused", %{
      conn: conn,
      runner_key: runner_key
    } do
      for {verb, path} <- [
            {"GET", "/api/auth/me"},
            {"GET", "/api/conversations"},
            {"POST", "/api/conversations"},
            {"GET", "/api/vaults"},
            {"GET", "/api/runners"},
            {"POST", "/api/auth/api-keys"},
            {"POST", "/api/runners/keys"}
          ] do
        resp = conn |> as(runner_key) |> dispatch(@endpoint, verb, path)
        assert resp.status == 403, "#{verb} #{path} answered #{resp.status}"
        assert insufficient?(resp.resp_body)
      end
    end

    test "other methods on the socket path are refused", %{conn: conn, runner_key: runner_key} do
      resp = conn |> as(runner_key) |> dispatch(@endpoint, "POST", "/api/runners/ws?name=mini")
      assert resp.status == 403
    end
  end

  describe "GET /api/runners/ws with a runner key" do
    test "registers the bound name", %{conn: conn, runner_key: runner_key, user: user} do
      # The test adapter cannot complete a real WebSocket upgrade, so it is
      # stubbed to report what it was handed. The controller
      # registers the runner and only then upgrades, so reaching it proves the
      # key got past authentication and the gate under its bound name.
      test_pid = self()

      Mimic.stub(WebSockAdapter, :upgrade, fn conn, handler, state, _opts ->
        send(test_pid, {:upgraded, handler, state})
        # Not a 101: the schema guard has no body to validate one against, so the
        # stub answers with a shape the operation declares.
        conn |> Plug.Conn.put_status(400) |> Phoenix.Controller.json(%{error: "stubbed"})
      end)

      conn
      |> as(runner_key)
      |> Plug.Conn.put_req_header("upgrade", "websocket")
      |> get("/api/runners/ws", %{"name" => "mini", "hostname" => "mini.local"})

      assert_receive {:upgraded, Managoat.Runner.Connection, %{name: "mini"}}
      assert %{name: "mini", hostname: "mini.local"} = Runners.get_runner_by_name(user.id, "mini")
    end

    test "without an upgrade it is past the gate and answers 400, registering nothing", %{
      conn: conn,
      runner_key: runner_key,
      user: user
    } do
      assert %{"error" => "not_a_websocket"} =
               conn
               |> as(runner_key)
               |> get("/api/runners/ws", %{"name" => "mini"})
               |> json_response(400)

      assert Runners.list_runners(user.id) == []
    end

    test "another name is 403 runner_name_mismatch and registers nothing", %{
      conn: conn,
      runner_key: runner_key,
      user: user
    } do
      resp =
        conn
        |> as(runner_key)
        |> Plug.Conn.put_req_header("upgrade", "websocket")
        |> get("/api/runners/ws", %{"name" => "laptop"})

      assert %{"error" => "runner_name_mismatch"} = json_response(resp, 403)
      assert Runners.list_runners(user.id) == []
    end

    test "no name is 403 too", %{conn: conn, runner_key: runner_key} do
      assert %{"error" => "runner_name_mismatch"} =
               conn |> as(runner_key) |> get("/api/runners/ws") |> json_response(403)
    end

    test "a full key may still register any name", %{conn: conn, full_key: full_key} do
      assert %{"error" => "not_a_websocket"} =
               conn
               |> as(full_key)
               |> get("/api/runners/ws", %{"name" => "laptop"})
               |> json_response(400)
    end

    test "a sprite key is still refused", %{conn: conn, user: user} do
      {_record, sprite_key} = insert_sprite_api_key(user)

      assert %{"reason" => "insufficient_scope"} =
               conn
               |> as(sprite_key)
               |> get("/api/runners/ws", %{"name" => "mini"})
               |> json_response(403)
    end
  end

  describe "POST /api/runners/keys" do
    test "a full key mints one, shown once", %{conn: conn, full_key: full_key, user: user} do
      body =
        conn
        |> as(full_key)
        |> post_json("/api/runners/keys", %{name: "box-1"})
        |> json_response(201)

      assert %{"id" => id, "runner_name" => "box-1", "key" => raw, "prefix" => prefix} = body
      assert String.starts_with?(raw, prefix)

      assert {:ok, _user, %ApiKey{scopes: ["runner"], runner_name: "box-1", id: ^id}} =
               Accounts.authenticate_api_key(raw)

      # It is never readable again: not in the key list, not by id.
      listed = build_conn() |> as(full_key) |> get("/api/auth/api-keys") |> json_response(200)
      refute Enum.any?(listed["data"], &Map.has_key?(&1, "key"))
      refute Jason.encode!(listed) =~ raw
      assert Enum.find(listed["data"], &(&1["id"] == id))["runner_name"] == "box-1"

      # And the new key does connect its name.
      assert %{"error" => "not_a_websocket"} =
               build_conn()
               |> as(raw)
               |> get("/api/runners/ws", %{"name" => "box-1"})
               |> json_response(400)

      actions = user.id |> Fountain.Audit.list_recent_for_user(10) |> Enum.map(& &1.action)
      assert "api_key.created" in actions
    end

    test "a sprite key gets 403", %{conn: conn, user: user} do
      {_record, sprite_key} = insert_sprite_api_key(user)

      assert %{"reason" => "insufficient_scope"} =
               conn
               |> as(sprite_key)
               |> post_json("/api/runners/keys", %{name: "box-1"})
               |> json_response(403)
    end

    test "a runner key gets 403", %{conn: conn, runner_key: runner_key} do
      assert %{"reason" => "insufficient_scope"} =
               conn
               |> as(runner_key)
               |> post_json("/api/runners/keys", %{name: "other"})
               |> json_response(403)
    end

    test "a bad or missing name is 422", %{conn: conn, full_key: full_key} do
      assert conn
             |> as(full_key)
             |> post_json("/api/runners/keys", %{name: "Not Valid"})
             |> json_response(422)

      assert build_conn()
             |> as(full_key)
             |> post_json("/api/runners/keys", %{})
             |> json_response(422)
    end
  end

  describe "revoking a runner key" do
    test "stops it authenticating and hangs up the live runner", %{
      conn: conn,
      full_key: full_key,
      runner_key: runner_key,
      runner_record: record,
      user: user
    } do
      {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
      {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")
      on_exit(fn -> FakeDaemon.stop(daemon) end)

      pid = Runners.whereis(runner.id)
      ref = Process.monitor(pid)

      assert conn |> as(full_key) |> delete("/api/auth/api-keys/#{record.id}") |> response(204)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert Runners.get_runner(runner.id, user.id)

      assert %{"reason" => "api_key_revoked"} =
               build_conn()
               |> as(runner_key)
               |> get("/api/runners/ws", %{"name" => "mini"})
               |> json_response(401)
    end
  end

  describe "the key record" do
    test "a runner key carries exactly one scope and a name", %{user: user} do
      mint = &Accounts.create_api_key(user.id, "k", &1)

      assert {:error, cs} = mint.(scopes: ["runner"])
      assert %{runner_name: ["can't be blank"]} = errors_on(cs)

      assert {:error, cs} = mint.(scopes: ["runner", "full"], runner_name: "mini")
      assert %{scopes: ["runner cannot be combined with another scope"]} = errors_on(cs)

      assert {:error, cs} = mint.(scopes: ["full"], runner_name: "mini")
      assert %{runner_name: ["is only allowed on a runner key"]} = errors_on(cs)

      assert {:error, cs} = mint.(scopes: ["runner"], runner_name: "Bad Name")
      assert %{runner_name: [_]} = errors_on(cs)
    end

    test "the table refuses a runner key with no name, written around the changeset", %{
      user: user
    } do
      {record, _raw} = insert_api_key(user)

      assert_raise Ecto.ConstraintError, ~r/api_keys_runner_name_matches_scope/, fn ->
        record |> Ecto.Changeset.change(scopes: ["runner"]) |> Repo.update!()
      end

      assert_raise Ecto.ConstraintError, ~r/api_keys_runner_name_matches_scope/, fn ->
        record |> Ecto.Changeset.change(runner_name: "mini") |> Repo.update!()
      end
    end
  end

  defp insufficient?(body), do: match?(%{"reason" => "insufficient_scope"}, Jason.decode!(body))
end
