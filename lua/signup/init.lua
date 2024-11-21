local api = vim.api
local Config = require("signup.config")
local Highlight = require("signup.highlight")
local Util = require("signup.util")

---@class SignatureHelp
---@field buf number?
---@field win number?
---@field visible boolean
---@field _ns number
---@field config SignupConfig
local SignatureHelp = {}
SignatureHelp.__index = SignatureHelp

function SignatureHelp.new()
  local self = setmetatable({
    buf = nil,
    win = nil,
    visible = false,
    _ns = api.nvim_create_namespace("signup"),
    config = Config.options,
  }, SignatureHelp)
  return self
end

function SignatureHelp:create_float_window(contents, signature)
  local width = math.min(self.config.max_width, vim.o.columns)
  local height = math.min(#contents, self.config.max_height)

  -- Calculate position to show above the cursor
  local cursor = api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]

  local win_config = {
    relative = "cursor",
    win = 0,
    row = row > 0 and row - 1 or 0,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = self.config.border,
    zindex = 100,
  }

  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, win_config)
  else
    self.buf = api.nvim_create_buf(false, true)
    self.win = api.nvim_open_win(self.buf, false, win_config)
  end

  -- Set buffer options
  api.nvim_buf_set_option(self.buf, "modifiable", true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, contents)
  api.nvim_buf_set_option(self.buf, "modifiable", false)
  api.nvim_buf_set_option(self.buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.buf, "bufhidden", "wipe")

  -- Set window options
  api.nvim_win_set_option(self.win, "foldenable", false)
  api.nvim_win_set_option(self.win, "wrap", self.config.wrap)
  api.nvim_win_set_option(self.win, "winblend", self.config.winblend)

  self:set_active_parameter_highlights(signature)
  self.visible = true
end

function SignatureHelp:set_active_parameter_highlights(signature)
  if not self.buf or not api.nvim_buf_is_valid(self.buf) then return end

  api.nvim_buf_clear_namespace(self.buf, self._ns, 0, -1)

  if signature and signature.activeParameter and signature.parameters then
    local param = signature.parameters[signature.activeParameter + 1]
    if param then
      local start_idx, end_idx

      if type(param.label) == "string" then
        local line_text = api.nvim_buf_get_lines(self.buf, 0, 1, false)[1]
        start_idx = line_text:find(vim.pesc(param.label), 1, true)
        if start_idx then
          end_idx = start_idx + #param.label - 1
        end
      elseif type(param.label) == "table" and #param.label == 2 then
        start_idx = param.label[1] + 1
        end_idx = param.label[2]
      end

      if start_idx and end_idx then
        Highlight.safe_add_highlight(
          self.buf,
          self._ns,
          0,
          start_idx - 1,
          end_idx,
          "LspSignatureActiveParameter"
        )
      end
    end
  end
end

function SignatureHelp:close()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_close(self.win, true)
    self.win = nil
    self.buf = nil
  end
  self.visible = false
end

function SignatureHelp:format_signature(signature)
  local contents = {}

  -- Add signature
  table.insert(contents, signature.label)

  -- Add parameter documentation if available
  if signature.activeParameter and signature.parameters then
    local param = signature.parameters[signature.activeParameter + 1]
    if param and param.documentation then
      local doc = type(param.documentation) == "table"
          and param.documentation.value
          or param.documentation

      table.insert(contents, string.rep("─", 40))
      table.insert(contents, self.config.icons.parameter .. " " .. doc)
    end
  end

  return contents
end

function SignatureHelp:display(result)
  if not result or not result.signatures or #result.signatures == 0 then
    self:close()
    return
  end

  local signature = result.signatures[result.activeSignature and result.activeSignature + 1 or 1]
  local contents = self:format_signature(signature)
  self:create_float_window(contents, signature)
end

local M = {}

function M.setup(opts)
  Config.setup(opts)

  local signature_help = SignatureHelp.new()

  Highlight.setup_highlights(Config.options)
  Highlight.create_autocmds(Config.options)

  -- Override default LSP signature handler
  vim.lsp.handlers["textDocument/signatureHelp"] = function(_, result, ctx)
    signature_help:display(result)
  end

  -- Setup auto-open triggers
  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local bufnr = args.buf
      local client = vim.lsp.get_client_by_id(args.data.client_id)

      if client and client.server_capabilities.signatureHelpProvider then
        local trigger_chars = client.server_capabilities.signatureHelpProvider.triggerCharacters or {}

        local check_trigger = Util.debounce(Config.options.auto_open.throttle, function()
          local char = Util.get_current_char(bufnr)
          if vim.tbl_contains(trigger_chars, char) then
            vim.lsp.buf.signature_help()
          end
        end)

        -- Set up text change triggers
        vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
          buffer = bufnr,
          callback = check_trigger,
        })

        -- Set up keybinding
        vim.keymap.set("n", Config.options.toggle_key, vim.lsp.buf.signature_help, {
          buffer = bufnr,
          desc = "Toggle signature help"
        })
      end
    end,
  })
end

return M
