defmodule Fountain.Conversations.SessionInfo do
  @moduledoc "Applies titles supplied by the harness through ACP session metadata."

  alias Fountain.Conversations
  alias Fountain.Conversations.Redaction

  require Logger

  @doc "Apply a title patch. Omission leaves the title alone; null clears a harness title."
  def apply(conversation_id, line) do
    case Managoat.ACP.Protocol.classify_line(line) do
      {:notification, "session/update",
       %{"update" => %{"sessionUpdate" => "session_info_update", "title" => title}}}
      when is_binary(title) or is_nil(title) ->
        # ownership: the TurnMachine passes its server's conversation id. The
        # peer's sessionId is never used to choose the row receiving the title.
        # Redact the decoded value before transformations can break a secret
        # match or truncate it into a credential fragment.
        title = conversation_id |> Redaction.redact(title) |> normalize()
        Conversations._unsafe_update_harness_title(conversation_id, title)

      _ ->
        :ok
    end
  rescue
    error ->
      # A failed metadata write must not cost the harness its active turn.
      # Database exception messages can contain parameters, including secrets.
      Logger.warning(
        "conv #{conversation_id}: session title update failed (#{inspect(error.__struct__)})"
      )

      :ok
  end

  defp normalize(nil), do: nil

  defp normalize(title) do
    title =
      title
      |> String.replace("\0", "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, 120)
      |> fit_column(255)

    if title == "", do: nil, else: title
  end

  # PostgreSQL varchar counts code points; Elixir's title limit counts
  # graphemes. Keep complete graphemes while respecting both limits.
  defp fit_column(title, remaining) do
    case String.next_grapheme(title) do
      {grapheme, rest} ->
        size = grapheme |> String.to_charlist() |> length()

        if size <= remaining,
          do: grapheme <> fit_column(rest, remaining - size),
          else: ""

      nil ->
        ""
    end
  end
end
