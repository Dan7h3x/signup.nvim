# signup.nvim

A little (smart maybe) lsp signature helper for neovim.

---

# Neovim Signature Help Plugin

This Neovim plugin provides a signature help feature for LSP (Language Server Protocol) clients. It displays function signatures and parameter information in a floating window as you type in insert mode or move the cursor in normal mode. The plugin also includes a notification system to display messages with different levels of severity (info, warning, error).

# ScreenShots (WIP)

![Screenshot 1](https://github.com/user-attachments/assets/1ba206b1-cde8-41f4-9abd-f8501c6b16e1)
![Screenshot 2](https://github.com/user-attachments/assets/aba63fe7-a302-4c9d-9f4a-ce28c9c35c03)
![Screenshot 3](https://github.com/user-attachments/assets/986f0bcb-aecf-4483-8210-83b93cfd72d2)

## Features

- **Signature Help**: Displays function signatures and parameter information in a floating window.
- **Toggle Mode**: Toggle signature help in normal mode.
- **Customizable**: Highly customizable with options for icons, colors, and more.
- **Integration**: Integrates with nvim-treesitter for syntax highlighting.
- **Notifications**: Displays notifications for errors, warnings, and info messages.

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

Add the following to your `init.lua`:

```lua
require("lazy").setup({
  {
    "Dan7h3x/signup.nvim",
    branch = "main",
    config = function()
      require("signup").setup({
        -- Your configuration options here
      })
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

The plugin comes with a default configuration, but you can customize it according to your preferences. Here are the available options:

```lua
require('signup').setup(
  {
    win = nil,
    buf = nil,
    timer = nil,
    visible = false,
    current_signatures = nil,
    enabled = false,
    normal_mode_active = false,
    config = {
      silent = false,
      number = true,
      icons = {
        parameter = " ",
        method = " ",
        documentation = " ",
      },
      colors = {
        parameter = "#86e1fc",
        method = "#c099ff",
        documentation = "#4fd6be",
      },
      active_parameter_colors = {
        bg = "#86e1fc",
        fg = "#1a1a1a",
      },
      border = "solid",
      winblend = 10,
    }
  }
)
```

### Options

- **silent**: If `true`, suppresses notifications. Default is `false`.
- **number**: If `true`, displays the signature index. Default is `true`.
- **icons**: Custom icons for method, parameter, and documentation.
- **colors**: Custom colors for method, parameter, and documentation.
- **border**: Border style for the floating window. Default is `"rounded"`.
- **winblend**: Transparency level for the floating window. Default is `10`.
- **override**: If `true`, overrides the default LSP handler for `textDocument/signatureHelp`. Default is `true`.

## Usage

### Toggle Signature Help in Normal Mode

You can toggle the signature help in normal mode using the default keybinding `<C-k>`. You can customize this keybinding in the setup function:

```lua
require('signup').setup({
  toggle_key = "<C-k>", -- Customize the toggle key here
})
```

### Trigger Signature Help in Insert Mode

The signature help is automatically triggered when you move the cursor or change text in insert mode.

### Notifications

The plugin includes a notification system to display messages with different levels of severity (info, warning, error). These notifications are displayed in a floating window and automatically disappear after a few seconds.

## Highlight Groups

The plugin defines the following highlight groups:

- **LspSignatureActiveParameter**: Highlight for the active parameter.
- **SignatureHelpMethod**: Highlight for method icons.
- **SignatureHelpParameter**: Highlight for parameter icons.
- **SignatureHelpDocumentation**: Highlight for documentation icons.
- **NotificationInfo**: Highlight for info notifications.
- **NotificationWarn**: Highlight for warning notifications.
- **NotificationError**: Highlight for error notifications.

## Examples

### Customizing Icons and Colors

```lua
require('signup').setup({
  icons = {
    parameter = " ",
    method = " ",
    documentation = " ",
  },
  colors = {
    parameter = "#ffa500",
    method = "#8a2be2",
    documentation = "#008000",
  },
})
```

### Disabling Notifications

```lua
require('signup').setup({
  silent = true,
})
```

## Contributing

Contributions are welcome! Please feel free to submit a pull request or open an issue if you encounter any problems or have suggestions for improvements.

## License

This plugin is licensed under the MIT License. See the [LICENSE](LICENSE) file for more details.

---
