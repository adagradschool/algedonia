defmodule AlgedoniaWeb.TerminalAccessTokenTest do
  use ExUnit.Case, async: true

  alias AlgedoniaWeb.TerminalAccessToken

  describe "sign/2 and verify/1" do
    test "round-trip returns original payload" do
      user_id = "11111111-1111-4111-8111-111111111111"
      loop_id = "22222222-2222-4222-8222-222222222222"
      token = TerminalAccessToken.sign(user_id, loop_id)
      assert {:ok, payload} = TerminalAccessToken.verify(token)
      assert payload.user_id == user_id
      assert payload.loop_id == loop_id
    end

    test "expired token returns error" do
      token =
        TerminalAccessToken.sign(
          "33333333-3333-4333-8333-333333333333",
          "44444444-4444-4444-8444-444444444444"
        )

      assert {:error, :expired} = TerminalAccessToken.verify(token, max_age: 0)
    end

    test "tampered token returns error" do
      token =
        TerminalAccessToken.sign(
          "55555555-5555-4555-8555-555555555555",
          "66666666-6666-4666-8666-666666666666"
        )

      tampered = token <> "tampered"
      assert {:error, :invalid} = TerminalAccessToken.verify(tampered)
    end

    test "payload contains string user_id and loop_id" do
      user_id = "77777777-7777-4777-8777-777777777777"
      loop_id = "88888888-8888-4888-8888-888888888888"
      token = TerminalAccessToken.sign(user_id, loop_id)
      assert {:ok, payload} = TerminalAccessToken.verify(token)
      assert payload.user_id == user_id
      assert payload.loop_id == loop_id
    end
  end
end
