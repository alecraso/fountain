defmodule Fountain.Conversations.SessionInfo do
  @moduledoc "Applies titles supplied by the harness through ACP session metadata."

  alias Fountain.Conversations

  @doc "Apply a title patch. Omission leaves the title alone; null clears a harness title."
  def apply(conversation_id, line) do
    case Managoat.ACP.Protocol.classify_line(line) do
      {:notification, "session/update",
       %{"update" => %{"sessionUpdate" => "session_info_update", "title" => title}}}
      when is_binary(title) or is_nil(title) ->
        # ownership: the TurnMachine passes its server's conversation id. The
        # peer's sessionId is never used to choose the row receiving the title.
        Conversations._unsafe_update_harness_title(conversation_id, normalize(title))

      _ ->
        :ok
    end
  end

  defp normalize(nil), do: nil

  defp normalize(title) do
    title =
      title
      |> String.replace("\0", "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, 120)

    if title == "", do: nil, else: title
  end
end
