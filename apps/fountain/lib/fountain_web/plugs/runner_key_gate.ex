defmodule FountainWeb.Plugs.RunnerKeyGate do
  @moduledoc """
  The whole of what a `runner`-scoped API key may do (ADR 0022, arugula fork).

  A runner key sits on a machine where untrusted agent code runs, so it is
  held to one capability: connecting one named runner. It is checked at
  authentication, by `FountainWeb.Plugs.TenantAPIAuth`, as a **default-deny**
  with a one-route allow-list. The other `/api` guards are opt-in per scope
  block (`:require_full_scope`), so a route added tomorrow that nobody gives a
  guard would be open to a `sprite` key and, without this, to a runner key
  too. Here a route nobody thought of is refused.

    * Any route but `GET /api/runners/ws` — 403, `reason: "insufficient_scope"`.
    * That route with a `name` other than the key's bound one, or none — 403,
      `error: "runner_name_mismatch"`.

  Keys of every other scope pass through untouched.
  """

  alias Fountain.Accounts.ApiKey

  @allowed_path ["api", "runners", "ws"]

  @doc """
  `:ok` when the request may proceed, else `{:error, :insufficient_scope}` or
  `{:error, :runner_name_mismatch}`.
  """
  @spec admit(Plug.Conn.t(), ApiKey.t()) ::
          :ok | {:error, :insufficient_scope | :runner_name_mismatch}
  def admit(%Plug.Conn{} = conn, %ApiKey{} = key) do
    cond do
      not ApiKey.runner_key?(key) -> :ok
      not runner_socket?(conn) -> {:error, :insufficient_scope}
      conn.params["name"] == key.runner_name -> :ok
      true -> {:error, :runner_name_mismatch}
    end
  end

  defp runner_socket?(%Plug.Conn{method: "GET", path_info: @allowed_path}), do: true
  defp runner_socket?(%Plug.Conn{}), do: false
end
