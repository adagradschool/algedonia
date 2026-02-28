defmodule Algedonia.DiffParserTest do
  use ExUnit.Case, async: true

  alias Algedonia.DiffParser

  @sample_diff """
  diff --git a/lib/app.ex b/lib/app.ex
  index abc1234..def5678 100644
  --- a/lib/app.ex
  +++ b/lib/app.ex
  @@ -10,6 +10,8 @@ defmodule App do
     def start do
       IO.puts("hello")
  +    Logger.info("starting")
  +    init()
       :ok
     end
   end
  """

  @added_file_diff """
  diff --git a/lib/new_file.ex b/lib/new_file.ex
  new file mode 100644
  index 0000000..abc1234
  --- /dev/null
  +++ b/lib/new_file.ex
  @@ -0,0 +1,3 @@
  +defmodule NewFile do
  +  def hello, do: :world
  +end
  """

  @deleted_file_diff """
  diff --git a/lib/old_file.ex b/lib/old_file.ex
  deleted file mode 100644
  index abc1234..0000000
  --- a/lib/old_file.ex
  +++ /dev/null
  @@ -1,3 +0,0 @@
  -defmodule OldFile do
  -  def hello, do: :world
  -end
  """

  @renamed_file_diff """
  diff --git a/lib/old_name.ex b/lib/new_name.ex
  similarity index 100%
  rename from lib/old_name.ex
  rename to lib/new_name.ex
  """

  @binary_diff """
  diff --git a/image.png b/image.png
  index abc1234..def5678 100644
  Binary files a/image.png and b/image.png differ
  """

  describe "parse/1" do
    test "returns empty list for nil" do
      assert DiffParser.parse(nil) == []
    end

    test "returns empty list for empty string" do
      assert DiffParser.parse("") == []
    end

    test "returns empty list for whitespace-only string" do
      assert DiffParser.parse("   \n\n  ") == []
    end

    test "parses a modified file diff" do
      [file] = DiffParser.parse(@sample_diff)
      assert file.path == "lib/app.ex"
      assert file.old_path == nil
      assert file.status == :modified
      assert length(file.hunks) == 1

      [hunk] = file.hunks
      assert hunk.old_start == 10
      assert hunk.old_count == 6
      assert hunk.new_start == 10
      assert hunk.new_count == 8

      additions = Enum.filter(hunk.lines, &(&1.type == :addition))
      assert length(additions) == 2
      assert Enum.any?(additions, &(&1.content =~ "Logger.info"))
      assert Enum.any?(additions, &(&1.content =~ "init()"))
    end

    test "parses an added file" do
      [file] = DiffParser.parse(@added_file_diff)
      assert file.path == "lib/new_file.ex"
      assert file.status == :added
      assert length(file.hunks) == 1

      [hunk] = file.hunks
      lines = hunk.lines
      assert Enum.all?(lines, &(&1.type == :addition))
      assert length(lines) == 3
    end

    test "parses a deleted file" do
      [file] = DiffParser.parse(@deleted_file_diff)
      assert file.path == "lib/old_file.ex"
      assert file.status == :deleted
      assert length(file.hunks) == 1

      [hunk] = file.hunks
      lines = hunk.lines
      assert Enum.all?(lines, &(&1.type == :deletion))
      assert length(lines) == 3
    end

    test "parses a renamed file" do
      [file] = DiffParser.parse(@renamed_file_diff)
      assert file.path == "lib/new_name.ex"
      assert file.old_path == "lib/old_name.ex"
      assert file.status == :renamed
      assert file.hunks == []
    end

    test "parses a binary file diff" do
      [file] = DiffParser.parse(@binary_diff)
      assert file.path == "image.png"
      assert file.status == :binary
      assert file.hunks == []
    end

    test "parses multiple files in one diff" do
      multi_diff = @sample_diff <> @added_file_diff
      files = DiffParser.parse(multi_diff)
      assert length(files) == 2
      paths = Enum.map(files, & &1.path)
      assert "lib/app.ex" in paths
      assert "lib/new_file.ex" in paths
    end

    test "tracks correct line numbers for additions and deletions" do
      [file] = DiffParser.parse(@sample_diff)
      [hunk] = file.hunks

      context_line = Enum.find(hunk.lines, &(&1.content =~ "start do"))
      assert context_line.type == :context
      assert context_line.old_line == 10
      assert context_line.new_line == 10

      addition = Enum.find(hunk.lines, &(&1.content =~ "Logger.info"))
      assert addition.type == :addition
      assert addition.old_line == nil
      assert addition.new_line == 12
    end
  end

  describe "extract_hunk_context/4" do
    test "extracts surrounding context for a line" do
      files = DiffParser.parse(@sample_diff)
      context = DiffParser.extract_hunk_context(files, "lib/app.ex", 12, 2)
      assert context =~ "Logger.info"
    end

    test "returns empty string for unknown file" do
      files = DiffParser.parse(@sample_diff)
      assert DiffParser.extract_hunk_context(files, "unknown.ex", 1) == ""
    end

    test "returns empty string for line not in any hunk" do
      files = DiffParser.parse(@sample_diff)
      assert DiffParser.extract_hunk_context(files, "lib/app.ex", 999) == ""
    end
  end
end
