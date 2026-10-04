defmodule FountainWeb.RunnerJSON do
  @moduledoc "JSON views for self-hosted runners (ADR 0022)."

  alias Fountain.Runners.Runner

  def index(%{runners: runners}), do: %{data: Enum.map(runners, &summary/1)}

  @doc "Response for runner key minting — includes the raw key (shown once only)."
  def key_created(%{key: key, raw_key: raw_key}) do
    %{
      id: key.id,
      runner_name: key.runner_name,
      key: raw_key,
      prefix: key.key_prefix,
      created_at: key.inserted_at
    }
  end

  def show(%{runner: runner, online: online}), do: summary(%{runner: runner, online: online})

  defp summary(%{runner: %Runner{} = runner, online: online}) do
    %{
      id: runner.id,
      name: runner.name,
      hostname: runner.hostname,
      os: runner.os,
      arch: runner.arch,
      version: runner.version,
      root: runner.root,
      online: online,
      connected_at: runner.connected_at,
      last_seen_at: runner.last_seen_at,
      created_at: runner.inserted_at
    }
  end
end
