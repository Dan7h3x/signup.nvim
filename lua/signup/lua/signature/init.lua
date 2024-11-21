local api = vim.api
local SignatureWindow = require("signature.window")
local Config = require("signature.config")

---@class SignatureManager
---@field private window SignatureWindow
---@field private active boolean
---@field private config table
local SignatureManager = {}
SignatureManager.__index = SignatureManager

function SignatureManager.new()
  local self = setmetatable({
    window = SignatureWindow.new(),
    active = false,
    config = Config.get(),
  }, SignatureManager)
  return self
end

function SignatureManager:handle_signature(result, ctx)
  if not result or vim.tbl_isempty(result.signatures or {}) then
    self.window:hide()
    return
  end

  -- Don't show if completion is visible and configured to hide
  if self.config.hide_on_completion and vim.fn.pumvisible() == 1 then
    self.window:hide()
    return
  end

  local signature = result.signatures[result.activeSignature and result.activeSignature + 1 or 1]
  if not signature then return end

  -- Dynamic parameter detection
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local current_param = self:detect_current_parameter(line, cursor_pos[2], signature)

  self.window:display(signature, current_param or result.activeParameter)
end

function SignatureManager:detect_current_parameter(line, col, signature)
  if not signature.parameters or #signature.parameters == 0 then
    return nil
  end

  -- Get text from start of line to cursor
  local text_before_cursor = line:sub(1, col)
  
  -- Find the last opening parenthesis before cursor
  local last_open = text_before_cursor:match(".*%(")
  if not last_open then return 0 end

  -- Count commas to determine parameter position
  local param_text = text_before_cursor:sub(#last_open + 1)
  local param_count = 0
  
  local in_string = false
  local string_char = nil
  local depth = 0

  for i = 1, #param_text do
    local char = param_text:sub(i, i)
    
    -- Handle string literals
    if char == '"' or char == "'" then
      if not in_string then
        in_string = true
        string_char = char
      elseif string_char == char then
        in_string = false
      end
    end
    
    -- Handle nested parentheses
    if not in_string then
      if char == '(' then
        depth = depth + 1
      elseif char == ')' then
        depth = depth - 1
      elseif char == ',' and depth == 0 then
        param_count = param_count + 1
      end
    end
  end

  return math.min(param_count, #signature.parameters - 1)
end

function SignatureManager:setup_buffer(bufnr, client)
  if not client.server_capabilities.signatureHelpProvider then return end

  local trigger_chars = vim.tbl_extend("keep",
    self.config.trigger_chars,
    client.server_capabilities.signatureHelpProvider.triggerCharacters or {}
  )

  -- Efficient trigger character handling
  api.nvim_create_autocmd("InsertCharPre", {
    buffer = bufnr,
    callback = function()
      if vim.tbl_contains(trigger_chars, vim.v.char) then
        vim.schedule(function()
          vim.lsp.buf.signature_help()
        end)
      end
    end,
  })

  -- Handle completion menu visibility
  if self.config.hide_on_completion then
    api.nvim_create_autocmd("CompleteChanged", {
      buffer = bufnr,
      callback = function()
        self.window:hide()
      end,
    })
  end
end

local M = {}

function M.setup(opts)
  Config.setup(opts)
  
  local manager = SignatureManager.new()

  -- Override the default signature help handler
  vim.lsp.handlers["textDocument/signatureHelp"] = function(_, result, ctx)
    manager:handle_signature(result, ctx)
  end

  -- Setup buffer-local configuration on LSP attach
  api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client then
        manager:setup_buffer(args.buf, client)
      end
    end,
  })
end

return M 