defmodule BotArmyGithub.Indexing.FilesystemWalkerTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.FilesystemWalker

  setup do
    # Create a temporary test directory structure
    test_dir = Path.join(System.tmp_dir!(), "test_repo_#{System.unique_integer()}")
    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "walk/2" do
    test "walks empty directory", %{test_dir: test_dir} do
      {:ok, files} = FilesystemWalker.walk(test_dir)
      assert files == []
    end

    test "detects files with correct languages", %{test_dir: test_dir} do
      # Create test files
      File.write!(Path.join(test_dir, "test.ex"), "defmodule Test do\nend")
      File.write!(Path.join(test_dir, "test.py"), "print('hello')")
      File.write!(Path.join(test_dir, "test.js"), "console.log('hello')")

      {:ok, files} = FilesystemWalker.walk(test_dir)

      assert length(files) == 3
      assert Enum.any?(files, &(&1.language == :elixir))
      assert Enum.any?(files, &(&1.language == :python))
      assert Enum.any?(files, &(&1.language == :javascript))
    end

    test "marks text files correctly", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "readme.md"), "# Test")
      File.write!(Path.join(test_dir, "config.json"), "{}")

      {:ok, files} = FilesystemWalker.walk(test_dir)

      assert Enum.all?(files, & &1.is_text)
    end

    test "respects .gitignore patterns", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, ".gitignore"), "*.log\ntemp/")
      File.write!(Path.join(test_dir, "test.ex"), "")
      File.write!(Path.join(test_dir, "debug.log"), "")

      mkdir_path = Path.join(test_dir, "temp")
      File.mkdir!(mkdir_path)
      File.write!(Path.join(mkdir_path, "file.ex"), "")

      {:ok, files} = FilesystemWalker.walk(test_dir)

      # Should have test.ex and .gitignore, but not debug.log or files in temp/
      file_paths = Enum.map(files, & &1.path)
      assert Enum.member?(file_paths, "test.ex")
      refute Enum.member?(file_paths, "debug.log")
      refute Enum.any?(file_paths, &String.starts_with?(&1, "temp/"))
    end

    test "includes file metadata", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "test.ex"), "test content")

      {:ok, files} = FilesystemWalker.walk(test_dir)

      [file] = files
      assert file.path == "test.ex"
      assert file.language == :elixir
      assert file.size_bytes > 0
      assert file.is_text
      assert is_struct(file.last_modified, DateTime)
    end

    test "returns error for invalid path" do
      result = FilesystemWalker.walk("/nonexistent/path")
      assert {:error, {:invalid_path, _}} = result
    end
  end

  describe "detect_language/1" do
    test "detects language by extension" do
      assert FilesystemWalker.detect_language("test.ex") == :elixir
      assert FilesystemWalker.detect_language("script.py") == :python
      assert FilesystemWalker.detect_language("app.js") == :javascript
      assert FilesystemWalker.detect_language("style.css") == :unknown
      assert FilesystemWalker.detect_language("unknown.xyz") == :unknown
    end

    test "handles mixed case extensions" do
      assert FilesystemWalker.detect_language("test.EX") == :elixir
      assert FilesystemWalker.detect_language("test.PY") == :python
      assert FilesystemWalker.detect_language("test.Js") == :javascript
    end
  end

  describe "is_text_file?/1" do
    test "identifies text files" do
      assert FilesystemWalker.is_text_file?("readme.md")
      assert FilesystemWalker.is_text_file?("script.sh")
      assert FilesystemWalker.is_text_file?("config.json")
      assert FilesystemWalker.is_text_file?("test.ex")
    end

    test "rejects binary files" do
      refute FilesystemWalker.is_text_file?("image.png")
      refute FilesystemWalker.is_text_file?("archive.zip")
      refute FilesystemWalker.is_text_file?("binary.exe")
    end
  end
end
