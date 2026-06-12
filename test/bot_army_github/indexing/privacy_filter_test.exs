defmodule BotArmyGithub.Indexing.PrivacyFilterTest do
  use ExUnit.Case
  @moduletag :indexing

  alias BotArmyGithub.Indexing.PrivacyFilter

  describe "check_file/2 - private directories" do
    test "skips files in .git directory" do
      # "config" is matched as credentials pattern, so caught first
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".git/config")
      # "objects" doesn't match credentials, caught as private_directory
      assert {:skip, :private_directory} = PrivacyFilter.check_file("repo/.git/objects/abc123")
    end

    test "skips files in node_modules" do
      assert {:skip, :private_directory} =
               PrivacyFilter.check_file("node_modules/package/index.js")

      assert {:skip, :private_directory} =
               PrivacyFilter.check_file("src/node_modules/lib/file.js")
    end

    test "skips files in venv/virtualenv" do
      # .so files are also sensitive binaries, so they're caught as sensitive_file first
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("venv/lib/python.so")
      # shell scripts are text but still in private directory
      assert {:skip, :private_directory} = PrivacyFilter.check_file(".venv/bin/activate")
      assert {:skip, :private_directory} = PrivacyFilter.check_file("env/scripts/activate")
    end

    test "skips IDE directories" do
      assert {:skip, :private_directory} = PrivacyFilter.check_file(".vscode/settings.json")
      assert {:skip, :private_directory} = PrivacyFilter.check_file(".idea/workspace.xml")
      assert {:skip, :private_directory} = PrivacyFilter.check_file(".sublime/project")
    end

    test "skips build output directories" do
      # .o files are sensitive binaries, caught by sensitive_file first
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("build/output.o")
      # .js in dist is still in private directory
      assert {:skip, :private_directory} = PrivacyFilter.check_file("dist/bundle.js")
      # .next is a private directory
      assert {:skip, :private_directory} = PrivacyFilter.check_file(".next/server/pages.js")
    end
  end

  describe "check_file/2 - sensitive extensions" do
    test "skips binary executables" do
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("program.exe")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("library.dll")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("lib.so")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("lib.dylib")
    end

    test "skips compiled files" do
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("code.o")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("program.class")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("archive.jar")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("module.beam")
    end

    test "skips encrypted/credential files" do
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("data.gpg")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("cert.pem")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("key.key")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("cert.crt")
    end

    test "skips archive files" do
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("backup.zip")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("data.tar")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("compressed.gz")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("archive.7z")
    end
  end

  describe "check_file/2 - credential files" do
    test "skips environment files" do
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".env")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".env.local")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".env.production")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("config.local.yml")
    end

    test "skips AWS/cloud credential files" do
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".aws/credentials")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".gcp/service-account.json")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("gcloud-config")
    end

    test "skips SSH/Kube auth files" do
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".ssh/config")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".kube/config")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("authorized_keys")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("known_hosts")
    end

    test "skips database password files" do
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".pgpass")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("db_password.txt")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("connection_string.conf")
    end

    test "skips API token files" do
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".npmrc")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".yarnrc")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("npm_token")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("api_secret.txt")
    end

    test "skips case-insensitive credential patterns" do
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("SECRET_KEY.txt")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("API_PASSWORD")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file("Token.conf")
    end
  end

  describe "check_file/2 - gitignore patterns" do
    test "skips files matching gitignore patterns" do
      patterns = ["*.log", "tmp/*", "secrets/**"]

      assert {:skip, :gitignored} =
               PrivacyFilter.check_file("debug.log", gitignore_patterns: patterns)

      assert {:skip, :gitignored} =
               PrivacyFilter.check_file("tmp/data", gitignore_patterns: patterns)

      assert {:skip, :gitignored} =
               PrivacyFilter.check_file("secrets/config.yml", gitignore_patterns: patterns)
    end
  end

  describe "check_file/2 - allowed files" do
    test "allows normal source files" do
      assert {:ok, :allowed} = PrivacyFilter.check_file("main.ex")
      assert {:ok, :allowed} = PrivacyFilter.check_file("script.py")
      assert {:ok, :allowed} = PrivacyFilter.check_file("src/app.js")
      assert {:ok, :allowed} = PrivacyFilter.check_file("lib/utils.go")
    end

    test "allows normal configuration files" do
      assert {:ok, :allowed} = PrivacyFilter.check_file("mix.exs")
      assert {:ok, :allowed} = PrivacyFilter.check_file("package.json")
      assert {:ok, :allowed} = PrivacyFilter.check_file("Dockerfile")
      assert {:ok, :allowed} = PrivacyFilter.check_file(".gitignore")
    end

    test "allows normal documentation" do
      assert {:ok, :allowed} = PrivacyFilter.check_file("README.md")
      assert {:ok, :allowed} = PrivacyFilter.check_file("docs/api.md")
      assert {:ok, :allowed} = PrivacyFilter.check_file("CONTRIBUTING.rst")
    end
  end

  describe "get_config/0" do
    test "returns privacy configuration" do
      config = PrivacyFilter.get_config()

      assert is_list(config.private_directories)
      assert is_list(config.sensitive_extensions)
      assert is_list(config.credentials_patterns)
      assert is_boolean(config.check_content)

      # Verify key patterns are included
      assert ".git" in config.private_directories
      assert "node_modules" in config.private_directories
      assert ".vscode" in config.private_directories
      assert ".exe" in config.sensitive_extensions
      assert ".pem" in config.sensitive_extensions
    end
  end

  describe "private_directories/0" do
    test "returns list of private directories" do
      dirs = PrivacyFilter.private_directories()

      assert is_list(dirs)
      assert length(dirs) > 20

      # Verify categories
      assert ".git" in dirs
      assert "node_modules" in dirs
      assert "venv" in dirs
      assert ".vscode" in dirs
      assert "build" in dirs
      assert ".DS_Store" in dirs
    end
  end

  describe "sensitive_extensions/0" do
    test "returns list of sensitive extensions" do
      exts = PrivacyFilter.sensitive_extensions()

      assert is_list(exts)
      assert length(exts) > 30

      # Verify categories
      assert ".exe" in exts
      assert ".dll" in exts
      assert ".pem" in exts
      assert ".key" in exts
      assert ".zip" in exts
      assert ".db" in exts
    end
  end

  describe "credentials_patterns/0" do
    test "returns list of credential patterns" do
      patterns = PrivacyFilter.credentials_patterns()

      assert is_list(patterns)
      assert length(patterns) > 15

      # All should be regex patterns
      assert Enum.all?(patterns, &is_struct(&1, Regex))
    end

    test "patterns match common credential files" do
      patterns = PrivacyFilter.credentials_patterns()

      assert Enum.any?(patterns, &Regex.match?(&1, ".env"))
      assert Enum.any?(patterns, &Regex.match?(&1, "api_key"))
      assert Enum.any?(patterns, &Regex.match?(&1, "password"))
      assert Enum.any?(patterns, &Regex.match?(&1, "aws_secret"))
    end
  end

  describe "edge cases" do
    test "handles paths with multiple private directories" do
      assert {:skip, :private_directory} = PrivacyFilter.check_file(".git/node_modules/file.js")
    end

    test "handles case-insensitive extension matching" do
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("archive.ZIP")
      assert {:skip, :sensitive_file} = PrivacyFilter.check_file("program.EXE")
    end

    test "allows files with restricted words in safe contexts" do
      # ".env" as standalone file is skipped, but "env" in filename is ok
      assert {:ok, :allowed} = PrivacyFilter.check_file("environment.py")
      assert {:ok, :allowed} = PrivacyFilter.check_file("src/environment_config.js")
    end

    test "distinguishes between .env and .env-like files" do
      # Exact matches
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".env")
      assert {:skip, :credentials_file} = PrivacyFilter.check_file(".env.local")

      # Similar but safe
      assert {:ok, :allowed} = PrivacyFilter.check_file("setup_env.sh")
      assert {:ok, :allowed} = PrivacyFilter.check_file("environment.json")
    end
  end
end
