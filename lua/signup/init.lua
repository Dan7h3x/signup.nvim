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

  local cursor = api.nvim_win_get_cursor(0)
  local row = cursor[1] - api.nvim_win_get_cursor(0)[1]

  local win_config = {
    relative = "cursor",
    row = row + 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = self.config.border,
  }

  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, win_config)
    api.nvim_win_set_buf(self.win, self.buf)
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

      -- Handle different parameter label types
      if type(param.label) == "string" then
        local line_text = api.nvim_buf_get_lines(self.buf, 0, 1, false)[1]
        start_idx = line_text:find(vim.pesc(param.label))
        if start_idx then
          end_idx = start_idx + #param.label - 1
        end
      elseif type(param.label) == "table" and #param.label == 2 then
        start_idx = param.label[1] + 1
        end_idx = param.label[2]
      end

      -- Apply highlights if we found valid positions
      if start_idx and end_idx and start_idx > 0 and end_idx > start_idx then
        -- Add parameter highlight
        Highlight.safe_add_highlight(
          self.buf,
          self._ns,
          0,
          start_idx - 1,
          end_idx,
          "LspSignatureActiveParameter"
        )

        -- Add parameter hint inline (optional)
        if param.documentation and self.config.inline_hints then
          local hint = type(param.documentation) == "table" 
            and param.documentation.value 
            or param.documentation

          pcall(api.nvim_buf_set_extmark, self.buf, self._ns, 0, math.max(0, end_idx), {
            virt_text = {
              {" : ", "Comment"},
              {hint, "LspSignatureParameterHint"}
            },
            virt_text_pos = "inline"
          })
        end
      end
    end
  end
end

function SignatureHelp:close()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_close(self.win, true)
  end
  self.visible = false
end

function SignatureHelp:display(result, trigger)
  if not result or not result.signatures or #result.signatures == 0 then
    if not trigger and not self.config.silent then
      vim.notify("No signature help available", vim.log.levels.INFO)
    end
    self:close()
    return
  end

  local signature = result.signatures[result.activeSignature and result.activeSignature + 1 or 1]
  local contents = self:format_signature(signature)
  
  self:create_float_window(contents, signature)
end

function SignatureHelp:format_signature(signature)
  local contents = {}
  
  -- Add method name and opening parenthesis
  local header = signature.label
  table.insert(contents, header)
  
  -- Add documentation if available and active parameter info
  if signature.activeParameter and signature.parameters then
    local param = signature.parameters[signature.activeParameter + 1]
    if param and param.documentation then
      local doc = type(param.documentation) == "table" 
        and param.documentation.value 
        or param.documentation
      
      table.insert(contents, "")
      table.insert(contents, string.rep("─", 40))
      table.insert(contents, self.config.icons.parameter .. " " .. doc)
    end
  elseif signature.documentation then
    local doc = type(signature.documentation) == "table" 
      and signature.documentation.value 
      or signature.documentation
    
    table.insert(contents, "")
    table.insert(contents, string.rep("─", 40))
    table.insert(contents, self.config.icons.documentation .. " " .. doc)
  end
  
  return contents
end

local M = {}

function M.setup(opts)
  -- Initialize configuration
  Config.setup(opts)
  
  -- Create signature help instance
  local signature_help = SignatureHelp.new()
  
  -- Setup highlights
  Highlight.setup_highlights(Config.options)
  Highlight.create_autocmds(Config.options)
  
  -- Override default LSP signature handler if configured
  if Config.options.override then
    vim.lsp.handlers["textDocument/signatureHelp"] = function(_, result, ctx)
      signature_help:display(result)
    end
  end
  
  -- Setup auto-open triggers if enabled
  if Config.options.auto_open.enabled then
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
          
          -- Set up trigger events
          if Config.options.auto_open.trigger then
            vim.api.nvim_buf_create_user_command(bufnr, "SignatureHelpToggle", function()
              vim.lsp.buf.signature_help()
            end, {})
            
            vim.keymap.set("n", Config.options.toggle_key, "<cmd>SignatureHelpToggle<CR>", {
              buffer = bufnr,
              desc = "Toggle signature help"
            })
            
            vim.api.nvim_create_autocmd({"TextChangedI", "TextChangedP"}, {
              buffer = bufnr,
              callback = check_trigger,
            })
          end
          
          if Config.options.auto_open.luasnip then
            vim.api.nvim_create_autocmd("User", {
              pattern = "LuasnipInsertNodeEnter",
              buffer = bufnr,
              callback = check_trigger,
            })
          end
        end
      end,
    })
  end
end

return M
