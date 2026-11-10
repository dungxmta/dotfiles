-- How jdtls picks its JDKs:
-- * jdtls itself (needs Java 25+):
--     1. $JDTLS_JAVA_HOME if set
--     2. else newest JDK in find_jdks() dirs, if >= min_launcher_major
--     3. else warn and fall back to `java` on PATH
-- * Project runtime: the `java` your shell resolves in the project dir (any version
--   manager, e.g. mise pin) is the default; it is added even if outside find_jdks() dirs
-- * Other JDKs in find_jdks() dirs are registered too, for projects targeting them
-- * find_jdks() scans mise, sdkman, asdf, Homebrew, macOS, Linux dirs in that order and
--   stops at the first one with a Java 25+; reorder its list to change priority,
--   or set $JDTLS_JAVA_HOME

-- Minimum Java version jdtls (Mason) needs to run itself; bump when jdtls requires newer
local min_launcher_major = 25

-- Major Java version of a JDK home, read from its `release` file
local function jdk_major(home)
  if not vim.uv.fs_stat(home .. "/release") then
    return nil
  end
  local version = table.concat(vim.fn.readfile(home .. "/release"), "\n"):match('JAVA_VERSION="([%d.]+)')
  return version and tonumber(version:match("^1%.(%d+)") or version:match("^(%d+)"))
end

-- Lookups are cached per nvim session (the jdtls config is rebuilt on every java buffer);
-- restart nvim after installing a JDK or changing a project's pin
local cache = { jdks = nil, shell_home = {}, warned = false }

-- JDK homes from common install dirs (order = priority), up to the first dir with a jdtls-capable JDK
local function find_jdks()
  if cache.jdks then
    return vim.list_extend({}, cache.jdks) -- copy: caller inserts/sorts it
  end
  local patterns = {
    "~/.local/share/mise/installs/java/*", -- mise
    "~/.sdkman/candidates/java/*", -- sdkman
    "~/.asdf/installs/java/*", -- asdf
    "/opt/homebrew/opt/openjdk*/libexec/openjdk.jdk/Contents/Home", -- Homebrew formula
    "/Library/Java/JavaVirtualMachines/*/Contents/Home", -- macOS installers, Homebrew casks
    "/usr/lib/jvm/*", -- Linux packages
  }
  local jdks, seen = {}, {}
  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
      local home = vim.uv.fs_realpath(path) -- dedupe alias symlinks (temurin-21 -> temurin-21.0.13...)
      local major = home and not seen[home] and jdk_major(home)
      if major then
        seen[home] = true
        table.insert(jdks, { major = major, home = home })
      end
    end
    if vim.iter(jdks):any(function(jdk)
      return jdk.major >= min_launcher_major
    end) then
      break
    end
  end
  table.sort(jdks, function(a, b)
    return a.major > b.major
  end)
  cache.jdks = jdks
  return vim.list_extend({}, jdks)
end

-- JDK that `java` resolves to in `dir` (works through any version manager or shim)
local function shell_java_home(dir)
  if cache.shell_home[dir] == nil then
    local ok, res = pcall(function()
      return vim.system({ "java", "-XshowSettings:properties", "-version" }, { text = true, cwd = dir }):wait()
    end)
    local home = ok and res.stderr and res.stderr:match("java%.home = ([^\n]+)")
    cache.shell_home[dir] = home and vim.uv.fs_realpath(home) or false
  end
  return cache.shell_home[dir] or nil
end

-- Registered once here, not in the jdtls opts fn: that reruns per java buffer
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("java_indent", { clear = true }),
  pattern = "java",
  callback = function()
    vim.bo.expandtab = true -- insertSpaces = true
    vim.bo.shiftwidth = 4 -- controls indentation level
    vim.bo.tabstop = 4 -- tab character width (if used)
  end,
})

return {
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "google-java-format" } },
  },
  {
    "mfussenegger/nvim-jdtls",
    opts = {
      jdtls = function(opts)
        local jdks = find_jdks()

        -- jdtls itself needs Java 25+; override with JDTLS_JAVA_HOME
        local launcher = vim.env.JDTLS_JAVA_HOME
        if not launcher and jdks[1] and jdks[1].major >= min_launcher_major then
          launcher = jdks[1].home
        end
        if launcher then
          -- passed as an arg: JAVA_HOME gets overridden by version-manager shims (mise python3)
          table.insert(opts.cmd, 2, "--java-executable=" .. launcher .. "/bin/java")
        elseif not cache.warned then
          cache.warned = true
          vim.notify(
            "jdtls: no Java " .. min_launcher_major .. "+ found, using java on PATH (set JDTLS_JAVA_HOME)",
            vim.log.levels.WARN
          )
        end

        -- project runtime: shell's java is default; other installed JDKs available for projects targeting them
        local default_home = shell_java_home(opts.root_dir or vim.fn.getcwd())
        if default_home and not vim.iter(jdks):any(function(jdk)
          return jdk.home == default_home
        end) then
          local major = jdk_major(default_home)
          if major then
            table.insert(jdks, 1, { major = major, home = default_home })
          end
        end
        -- shell's JDK first so it wins when several JDKs share a major version
        table.sort(jdks, function(a, b)
          return a.home == default_home and b.home ~= default_home
        end)
        local runtimes, by_major = {}, {}
        for _, jdk in ipairs(jdks) do
          if not by_major[jdk.major] then
            by_major[jdk.major] = true
            local name = jdk.major <= 8 and ("JavaSE-1." .. jdk.major) or ("JavaSE-" .. jdk.major)
            table.insert(runtimes, { name = name, path = jdk.home, default = jdk.home == default_home or nil })
          end
        end

        opts.settings = {
          java = {
            configuration = {
              runtimes = runtimes,
            },
            format = {
              enabled = true,
              settings = {
                -- Use Google Java style guidelines for formatting
                -- Vendored from google/styleguide@505ba68 (removed upstream in 355ad72)
                url = vim.fn.stdpath("config") .. "/java/eclipse-java-google-style.xml",
                profile = "GoogleStyle",
              },
            },
            inlayHints = {
              parameterNames = {
                enabled = "all",
              },
            },
            eclipse = {
              downloadSources = true,
            },
            maven = {
              downloadSources = true,
            },
            references = {
              includeDecompiledSources = true,
            },
            referencesCodeLens = {
              enabled = true,
            },
            signatureHelp = { enabled = true },
            contentProvider = { preferred = "fernflower" }, -- Use fernflower to decompile library code
            -- Specify any completion options
            completion = {
              favoriteStaticMembers = {
                "org.hamcrest.MatcherAssert.assertThat",
                "org.hamcrest.Matchers.*",
                "org.hamcrest.CoreMatchers.*",
                "org.junit.jupiter.api.Assertions.*",
                "java.util.Objects.requireNonNull",
                "java.util.Objects.requireNonNullElse",
                "org.mockito.Mockito.*",
              },
              filteredTypes = {
                "com.sun.*",
                "io.micrometer.shaded.*",
                "java.awt.*",
                "jdk.*",
                "sun.*",
              },
            },
            -- Specify any options for organizing imports
            sources = {
              organizeImports = {
                starThreshold = 9999,
                staticStarThreshold = 9999,
              },
            },
            -- How code generation should act
            codeGeneration = {
              toString = {
                template = "${object.className}{${member.name()}=${member.value}, ${otherMembers}}",
              },
              hashCodeEquals = {
                useJava7Objects = true,
              },
              useBlocks = true,
            },
          },
        }

        return opts
      end,
    },
  },
}
