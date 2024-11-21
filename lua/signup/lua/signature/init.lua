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

  self.window:display(signature, result.activeParameter)
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