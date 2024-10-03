# signup.nvim

A little (smart maybe) lsp signature helper for neovim.

---

# Neovim Signature Help Plugin

This Neovim plugin provides a signature help feature for LSP (Language Server Protocol) clients. It displays function signatures and parameter information in a floating window as you type in insert mode or move the cursor in normal mode. The plugin also includes a notification system to display messages with different levels of severity (info, warning, error).

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
require('signup').setup({
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
  border = "rounded",
  winblend = 10,
  override = true, -- Override default LSP handler for signatureHelp
})
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

## Good Color Schemes

To make your signature help window look even better, you can use the following color schemes:

### Gruvbox

```lua
vim.cmd([[
  colorscheme gruvbox
  highlight NormalFloat guibg=#3c3836 guifg=#ebdbb2
  highlight FloatBorder guifg=#8ec07c
  highlight LspSignatureActiveParameter guifg=#fabd2f guibg=#3c3836 gui=bold
  highlight SignatureHelpMethod guifg=#83a598
  highlight SignatureHelpParameter guifg=#b8bb26
  highlight SignatureHelpDocumentation guifg=#d3869b
  highlight NotificationInfo guifg=#8ec07c guibg=#3c3836
  highlight NotificationWarn guifg=#fabd2f guibg=#3c3836
  highlight NotificationError guifg=#fb4934 guibg=#3c3836
]])
```

### Nord

```lua
vim.cmd([[
  colorscheme nord
  highlight NormalFloat guibg=#3b4252 guifg=#e5e9f0
  highlight FloatBorder guifg=#81a1c1
  highlight LspSignatureActiveParameter guifg=#88c0d0 guibg=#3b4252 gui=bold
  highlight SignatureHelpMethod guifg=#81a1c1
  highlight SignatureHelpParameter guifg=#a3be8c
  highlight SignatureHelpDocumentation guifg=#b48ead
  highlight NotificationInfo guifg=#81a1c1 guibg=#3b4252
  highlight NotificationWarn guifg=#ebcb8b guibg=#3b4252
  highlight NotificationError guifg=#bf616a guibg=#3b4252
]])
```

### OneDark

```lua
vim.cmd([[
  colorscheme onedark
  highlight NormalFloat guibg=#282c34 guifg=#abb2bf
  highlight FloatBorder guifg=#61afef
  highlight LspSignatureActiveParameter guifg=#e06c75 guibg=#282c34 gui=bold
  highlight SignatureHelpMethod guifg=#61afef
  highlight SignatureHelpParameter guifg=#98c379
  highlight SignatureHelpDocumentation guifg=#c678dd
  highlight NotificationInfo guifg=#61afef guibg=#282c34
  highlight NotificationWarn guifg=#e5c07b guibg=#282c34
  highlight NotificationError guifg=#e06c75 guibg=#282c34
]])
```

Feel free to customize these color schemes to match your personal preferences!

---
