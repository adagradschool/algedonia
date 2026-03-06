defmodule Algedonia.AccountsTest do
  use Algedonia.DataCase, async: true

  alias Algedonia.Accounts
  alias Algedonia.Accounts.User

  describe "get_or_create_user_from_github/1" do
    test "creates a user with a UUID id and GitHub profile fields" do
      attrs = %{
        github_id: 123_456,
        github_username: "octocat",
        name: "The Octocat",
        email: "octocat@example.com",
        avatar_url: "https://avatars.githubusercontent.com/u/123456"
      }

      assert {:ok, user} = Accounts.get_or_create_user_from_github(attrs)
      assert {:ok, _uuid} = Ecto.UUID.cast(user.id)
      assert user.github_id == 123_456
      assert user.github_username == "octocat"
      assert user.name == "The Octocat"
      assert user.email == "octocat@example.com"
      assert user.avatar_url == "https://avatars.githubusercontent.com/u/123456"
    end

    test "updates the existing user for the same github_id without creating duplicates" do
      assert {:ok, existing} =
               Accounts.get_or_create_user_from_github(%{
                 github_id: 9_999,
                 github_username: "old-login",
                 name: "Old Name",
                 email: "old@example.com",
                 avatar_url: "https://old.example/avatar.png"
               })

      assert {:ok, updated} =
               Accounts.get_or_create_user_from_github(%{
                 github_id: 9_999,
                 github_username: "new-login",
                 name: "New Name",
                 email: "new@example.com",
                 avatar_url: "https://new.example/avatar.png"
               })

      assert updated.id == existing.id
      assert updated.github_username == "new-login"
      assert updated.name == "New Name"
      assert updated.email == "new@example.com"
      assert updated.avatar_url == "https://new.example/avatar.png"
      assert Repo.aggregate(from(u in User, where: u.github_id == 9_999), :count, :id) == 1
    end
  end

  describe "github_id uniqueness" do
    test "database unique index rejects duplicate github_id inserts" do
      %User{}
      |> User.github_changeset(%{github_id: 11_111, github_username: "first", name: "First"})
      |> Repo.insert!()

      assert {:error, changeset} =
               %User{}
               |> User.github_changeset(%{
                 github_id: 11_111,
                 github_username: "second",
                 name: "Second"
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).github_id
    end
  end
end
