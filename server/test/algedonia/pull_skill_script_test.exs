defmodule Algedonia.PullSkillScriptTest do
  use ExUnit.Case, async: true

  @script_path Path.expand("../../../.algedonia/skills/pull/scripts/rebase_branch.sh", __DIR__)

  describe "pull helper script" do
    test "uses remote-branch rebase when origin branch exists" do
      %{local: local_repo, peer: peer_repo} = setup_git_repos!()
      branch = "feature/ALG-119"

      git!(local_repo, ["checkout", "-b", branch])
      commit!(local_repo, "feature base")
      git!(local_repo, ["push", "-u", "origin", branch])

      git!(peer_repo, ["fetch", "origin"])
      git!(peer_repo, ["checkout", "-b", branch, "origin/#{branch}"])
      commit!(peer_repo, "remote branch advance")
      git!(peer_repo, ["push", "origin", branch])

      commit!(local_repo, "local work")

      git!(peer_repo, ["checkout", "main"])
      commit!(peer_repo, "main advance")
      git!(peer_repo, ["push", "origin", "main"])

      {output, 0} = run_pull_script(local_repo)

      assert output =~
               "pull: branch #{branch} using remote-branch rebase via origin/#{branch}"

      refute output =~ "origin/main fallback"

      log = git!(local_repo, ["log", "--format=%s", "--max-count", "8"])
      assert log =~ "local work"
      assert log =~ "remote branch advance"
      assert log =~ "main advance"
    end

    test "falls back directly to origin/main when origin branch is missing" do
      %{local: local_repo, peer: peer_repo} = setup_git_repos!()
      branch = "feature/ALG-120"

      git!(local_repo, ["checkout", "-b", branch])
      commit!(local_repo, "local work")

      git!(peer_repo, ["checkout", "main"])
      commit!(peer_repo, "main advance")
      git!(peer_repo, ["push", "origin", "main"])

      {output, 0} = run_pull_script(local_repo)

      assert output =~
               "pull: branch #{branch} using origin/main fallback because refs/remotes/origin/#{branch} is missing"

      refute output =~ "remote-branch rebase"

      log = git!(local_repo, ["log", "--format=%s", "--max-count", "6"])
      assert log =~ "local work"
      assert log =~ "main advance"
    end
  end

  defp setup_git_repos! do
    root =
      Path.join(
        System.tmp_dir!(),
        "algedonia-pull-skill-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)

    origin_repo = Path.join(root, "origin.git")
    system_cmd!("git", ["init", "--bare", "--initial-branch=main", origin_repo], cd: root)

    seed_repo = Path.join(root, "seed")
    system_cmd!("git", ["clone", origin_repo, seed_repo], cd: root)
    configure_git_user!(seed_repo)
    File.write!(Path.join(seed_repo, "README.md"), "seed\n")
    git!(seed_repo, ["add", "README.md"])
    git!(seed_repo, ["commit", "-m", "initial commit"])
    git!(seed_repo, ["push", "origin", "main"])

    local_repo = Path.join(root, "local")
    peer_repo = Path.join(root, "peer")
    system_cmd!("git", ["clone", origin_repo, local_repo], cd: root)
    system_cmd!("git", ["clone", origin_repo, peer_repo], cd: root)
    configure_git_user!(local_repo)
    configure_git_user!(peer_repo)

    %{local: local_repo, peer: peer_repo}
  end

  defp configure_git_user!(repo) do
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
  end

  defp commit!(repo, message) do
    filename = "file-#{System.unique_integer([:positive])}.txt"
    File.write!(Path.join(repo, filename), message <> "\n")
    git!(repo, ["add", filename])
    git!(repo, ["commit", "-m", message])
  end

  defp run_pull_script(repo) do
    System.cmd(@script_path, [], cd: repo, stderr_to_stdout: true, env: git_env())
  end

  defp git!(repo, args) do
    system_cmd!("git", ["-C", repo | args], cd: repo)
  end

  defp system_cmd!(command, args, opts) do
    {output, status} =
      System.cmd(command, args, Keyword.merge([stderr_to_stdout: true, env: git_env()], opts))

    assert status == 0, """
    command failed: #{command} #{Enum.join(args, " ")}
    #{output}
    """

    output
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "Test User"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test User"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]
  end
end
