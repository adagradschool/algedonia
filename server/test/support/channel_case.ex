defmodule AlgedoniaWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import AlgedoniaWeb.ChannelCase

      @endpoint AlgedoniaWeb.Endpoint
    end
  end

  setup tags do
    Algedonia.DataCase.setup_sandbox(tags)
    :ok
  end
end
