return {
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "google-java-format" } },
  },
  {
    "mfussenegger/nvim-jdtls",
    opts = {
      jdtls = function(opts)
        vim.api.nvim_create_autocmd("FileType", {
          pattern = "java",
          callback = function()
            vim.bo.expandtab = true -- insertSpaces = true
            vim.bo.shiftwidth = 4 -- controls indentation level
            vim.bo.tabstop = 4 -- tab character width (if used)
          end,
        })

        opts.settings = {
          java = {
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
