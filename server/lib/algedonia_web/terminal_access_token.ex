defmodule AlgedoniaWeb.TerminalAccessToken do
  @moduledoc """
  Issues and verifies short-lived tokens used for direct terminal WebSocket access.
  """

  @salt "terminal_ws"

  def sign(user_id, loop_id) do
    Phoenix.Token.sign(AlgedoniaWeb.Endpoint, @salt, %{
      user_id: to_string(user_id),
      loop_id: to_string(loop_id)
    })
  end

  def verify(token, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, 600)
    Phoenix.Token.verify(AlgedoniaWeb.Endpoint, @salt, token, max_age: max_age)
  end
end
