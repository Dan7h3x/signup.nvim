# signup.nvim

A little (smart maybe) lsp signature helper for neovim.

---

# Neovim Signature Help Plugin

This Neovim plugin provides a signature help feature for LSP (Language Server Protocol) clients. I can't tell much, just watch the showcases.

# ScreenShots (WIP)

![Image](https://github.com/user-attachments/assets/5d6c5002-9f30-4f46-9795-a7f9c6540503)
![Image](https://github.com/user-attachments/assets/205e2b16-0927-4e6b-8e67-141f4dde31eb)
![Image](https://github.com/user-attachments/assets/13a379e2-f372-4aaf-a891-f69dab4184a5)
![Image](https://github.com/user-attachments/assets/1940c8aa-3e9a-4bbb-a18c-778004ba018b)

## Features

- **Signature Help**: Displays function signatures and parameter information in a floating window with rich `lsp` support.
- **Toggle Mode**: Toggle signature help in normal mode, `dock` mode.
- **Customizable**: Highly customizable with options for icons, colors, and more.
- **Integration**: Integrates with nvim-treesitter for syntax highlighting.

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

Add the following to your `init.lua` and use `main` branch always:

```lua
require("lazy").setup({
  {
    "Dan7h3x/signup.nvim",
    branch = "main",
    opts = {
          -- Your configuration options here
    },
    config = function(_,opts)
      require("signup").setup(opts)
    end
  }
})
```

### Using Vim-Plug

Add the following to your `init.vim`:

```vim
Plug "Dan7h3x/signup.nvim"
```

Then, in your `init.lua`:

```lua
lua << EOF
require('signup').setup({
  -- Your configuration options here
})
EOF
```

## Configuration

The plugin comes with a default configuration, but you can customize it
according to your preferences. Here are the available options:

```lua
{
    silent = true,
    icons = {
      parameter = "",
      method = "󰡱",
      documentation = "󱪙",
      type = "󰌗",
      default = "󰁔",
    },
    colors = {
      parameter = "#86e1fc",
      method = "#c099ff",
      documentation = "#4fd6be",
      default_value = "#a80888",
      type = "#f6c177",
    },
    active_parameter = true,   -- enable/disable active_parameter highlighting
    active_parameter_colors = {
      bg = "#86e1fc",
      fg = "#1a1a1a",
    },
    border = "rounded",
    dock_border = "rounded",
    winblend = 10,
    auto_close = true,
    trigger_chars = { "(", ",", ")" },
    max_height = 10,
    max_width = 40,
    floating_window_above_cur_line = true,
    debounce_time = 50,
    dock_toggle_key = "<Leader>sd",
    dock_mode = {
      enabled = false,
      position = "bottom",   -- "bottom", "top", or "middle"
      height = 4,            -- If > 1: fixed height in lines, if <= 1: percentage of window height (e.g., 0.3 = 30%)
      padding = 1,           -- Padding from window edges
      side = "right",        -- "right", "left", or "center"
      width_percentage = 40, -- Percentage of editor width (10-90%)
    },
  }
```

## Contributing

Contributions are welcome! Please feel free to submit a pull request or open an issue if you encounter any problems or have suggestions for improvements.

## License

This plugin is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

---

```

```
