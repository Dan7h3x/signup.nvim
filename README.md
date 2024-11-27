# signup.nvim

A little (smart maybe) lsp signature helper for neovim.

---

# Neovim Signature Help Plugin

This Neovim plugin provides a signature help feature for LSP (Language Server Protocol) clients. I can't tell much, just watch the showcases.

# ScreenShots (WIP)

![signup_1](https://github.com/user-attachments/assets/e9319dcf-1d9d-4567-a500-a24d38933cb6)
![signup_2](https://github.com/user-attachments/assets/192b0809-3e66-42bf-9e6e-c1eae744f7b8)
![signup_3](https://github.com/user-attachments/assets/ca43b7a0-63fa-469c-8db0-df7a49dab483)

![signup_def](https://github.com/user-attachments/assets/6c4d7e09-5baa-418f-a086-e60b4eb4b501)

We have `dock` mode but its under dev for now, please take low expectations:
![signup_dock](https://github.com/user-attachments/assets/40455737-a952-4a3f-ae1f-fadd7ad68ea2)

## Features

- **Signature Help**: Displays function signatures and parameter information in a floating window.
- **Toggle Mode**: Toggle signature help in normal mode.
- **Customizable**: Highly customizable with options for icons, colors, and more.
- **Integration**: Integrates with nvim-treesitter for syntax highlighting.
- **Notifications**: Displays notifications for errors, warnings, and info messages.

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
opts = {
    silent = false,
    number = true,
    icons = {
      parameter = "",
      method = "󰡱",
      documentation = "󱪙",
    },
    colors = {
      parameter = "#86e1fc",
      method = "#c099ff",
      documentation = "#4fd6be",
      default_value = "#a80888",
    },
    active_parameter_colors = {
      bg = "#86e1fc",
      fg = "#1a1a1a",
    },
    border = "solid",
    winblend = 10,
    auto_close = true,
    trigger_chars = { "(", "," },
    max_height = 10,
    max_width = 40,
    floating_window_above_cur_line = true,
    preview_parameters = true,
    debounce_time = 30,
    dock_toggle_key = "<Leader>sd",
    toggle_key = "<C-k>",
    dock_mode = {
      enabled = false,
      position = "bottom",
      height = 3,
      padding = 1,
    },
    render_style = {
      separator = true,
      compact = true,
      align_icons = true,
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
