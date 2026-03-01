defmodule AlgedoniaWeb.TerminalAccessTokenTest do
  use ExUnit.Case, async: true

  alias AlgedoniaWeb.TerminalAccessToken

  describe "sign/2 and verify/1" do
    test "round-trip returns original payload" do
      token = TerminalAccessToken.sign("user-123", "loop-456")
      assert {:ok, payload} = TerminalAccessToken.verify(token)
      assert payload.user_id == "user-123"
      assert payload.loop_id == "loop-456"
    end

    test "expired token returns error" do
      token = TerminalAccessToken.sign("user-123", "loop-456")
      assert {:error, :expired} = TerminalAccessToken.verify(token, max_age: 0)
    end

    test "tampered token returns error" do
      token = TerminalAccessToken.sign("user-123", "loop-456")
      tampered = token <> "tampered"
      assert {:error, :invalid} = TerminalAccessToken.verify(tampered)
    end

    test "payload contains string user_id and loop_id" do
      token = TerminalAccessToken.sign(42, "loop-789")
      assert {:ok, payload} = TerminalAccessToken.verify(token)
      assert payload.user_id == "42"
      assert payload.loop_id == "loop-789"
    end
  end
end
