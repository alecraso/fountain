defmodule Fountain.Conversations.TerminationClusterTest do
  use ExUnit.Case, async: true

  alias Fountain.Test.ConversationMessagePeer, as: Contract

  test "attribution reaches the remote actor's fence and its refusal reaches the caller" do
    receiver = peer()
    caller = peer()
    {:ok, actor} = :peer.call(receiver, Contract, :receiver, [])
    opts = [actor: "api", request_ip: "192.0.2.8", audit: false]

    assert {:error, :sandbox_unavailable} =
             :peer.call(caller, Contract, :request_termination, [actor, opts])

    assert {"sandbox", fence} = :peer.call(receiver, Contract, :fence, [])
    assert fence[:actor] == "api"
    assert fence[:request_ip] == "192.0.2.8"
    assert fence[:terminating_conversation_id] == "conversation"
    refute Keyword.has_key?(fence, :audit)
  end

  defp peer do
    # Standard IO controls the peers without turning the suite's VM into a
    # cluster member. Only the two disposable nodes use Erlang distribution.
    {:ok, peer, _node} =
      :peer.start(%{
        name: :peer.random_name(~c"termination"),
        connection: :standard_io,
        args:
          [~c"+S", ~c"2", ~c"-setcookie", ~c"termination-contract", ~c"-pa"] ++ :code.get_path()
      })

    on_exit(fn -> :peer.stop(peer) end)
    peer
  end
end
