local api = vim.api
local fn = vim.fn

---@class SignatureWindow
---@field private buf number?
---@field private win number?
---@field private ns number
---@field private config table
---@field private last_signature table?
local SignatureWindow = {}
SignatureWindow.__index = SignatureWindow

function SignatureWindow.new()
  local self = setmetatable({
    buf = nil,
    win = nil,
    ns = api.nvim_create_namespace("signature"),
    config = require("signature.config").get(),
    last_signature = nil,
  }, SignatureWindow)
  return self
end

---Create or get existing buffer
function SignatureWindow:ensure_buffer()
  if self.buf and api.nvim_buf_is_valid(self.buf) then
    return
  end

  self.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(self.buf, "buftype", "nofile")
  api.nvim_buf_set_option(self.buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(self.buf, "swapfile", false)
  api.nvim_buf_set_option(self.buf, "modifiable", false)
end

---Calculate optimal window position
---@return table
function SignatureWindow:calculate_position()
  local cursor_line = fn.winline()
  local screen_line = fn.line("w0")
  local position = {}

  -- Check if we have room above the cursor
  if cursor_line > self.config.max_height + 2 then
    position.anchor = "SW"
    position.row = 0
    position.col = 0
  else
    position.anchor = "NW"
    position.row = 1
    position.col = 0
  end

  return {
    relative = "cursor",
    row = position.row,
    col = position.col,
    anchor = position.anchor,
    style = "minimal",
    border = self.config.border_chars,
    zindex = 50,
  }
end

---Format signature content with rich formatting
---@param signature table
---@param active_param number?
---@return table
function SignatureWindow:format_content(signature, active_param)
  local contents = {}
  local label_parts = {}

  -- Format function name and parameters
  local fn_name, params_str = signature.label:match("^([^(]+)%((.*)%)$")
  if fn_name then
    table.insert(label_parts, {
      text = fn_name,
      hl = "SignatureFunction"
    })
    table.insert(label_parts, {
      text = "(",
      hl = "SignatureDelimiter"
    })

    -- Format parameters
    if signature.parameters and #signature.parameters > 0 then
      for i, param in ipairs(signature.parameters) do
        if i > 1 then
          table.insert(label_parts, {
            text = ", ",
            hl = "SignatureDelimiter"
          })
        end

        local param_text = type(param.label) == "table"
            and signature.label:sub(param.label[1] + 1, param.label[2])
            or param.label

        table.insert(label_parts, {
          text = param_text,
          hl = (i - 1 == active_param) and "SignatureActiveParameter" or "SignatureParameter"
        })
      end
    else
      table.insert(label_parts, {
        text = params_str,
        hl = "SignatureParameter"
      })
    end

    table.insert(label_parts, {
      text = ")",
      hl = "SignatureDelimiter"
    })
  end

  -- Construct the signature line
  local signature_line = {
    text = "󰊕 ",  -- Function icon
    parts = label_parts
  }
  table.insert(contents, signature_line)

  -- Add parameter documentation
  if active_param and signature.parameters and signature.parameters[active_param + 1] then
    local param = signature.parameters[active_param + 1]
    if param.documentation then
      table.insert(contents, {
        text = "├─ ",
        parts = {{
          text = self:format_markdown(param.documentation),
          hl = "SignatureParameterDoc"
        }}
      })
    end
  end

  -- Add general documentation
  if signature.documentation then
    table.insert(contents, {
      text = "└─ ",
      parts = {{
        text = self:format_markdown(signature.documentation),
        hl = "SignatureDoc"
      }}
    })
  end

  return contents
end

---Format markdown content
---@param content string|table
---@return string
function SignatureWindow:format_markdown(content)
  local text = type(content) == "table" and content.value or content
  -- Basic markdown formatting
  text = text:gsub("```.-```", "") -- Remove code blocks
           :gsub("`([^`]+)`", "%1") -- Remove inline code
           :gsub("^%s*[*-] ", "• ") -- Convert list items
           :gsub("\n%s*[*-] ", "\n• ") -- Convert list items
           :gsub("^%s+", "") -- Trim start
           :gsub("%s+$", "") -- Trim end
  return text
end

---Apply highlights to the buffer
---@param contents table
function SignatureWindow:apply_highlights(contents)
  api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  
  for line_num, content in ipairs(contents) do
    local col = #content.text
    for _, part in ipairs(content.parts) do
      api.nvim_buf_add_highlight(
        self.buf,
        self.ns,
        part.hl,
        line_num - 1,
        col,
        col + #part.text
      )
      col = col + #part.text
    end
  end
end

---Display the signature window
---@param signature table
---@param active_param number?
function SignatureWindow:display(signature, active_param)
  -- Skip if signature hasn't changed
  if self.last_signature and 
     vim.deep_equal(self.last_signature, {signature = signature, param = active_param}) then
    return
  end
  
  self:ensure_buffer()
  local contents = self:format_content(signature, active_param)
  
  -- Calculate dimensions
  local max_width = 0
  local rendered_lines = {}
  for _, content in ipairs(contents) do
    local line = content.text
    for _, part in ipairs(content.parts) do
      line = line .. part.text
    end
    table.insert(rendered_lines, line)
    max_width = math.max(max_width, fn.strdisplaywidth(line))
  end

  -- Apply size constraints
  local width = math.min(max_width + 2, self.config.max_width)
  local height = math.min(#contents, self.config.max_height)

  -- Create or update window
  local win_config = vim.tbl_extend("force", 
    self:calculate_position(),
    { width = width, height = height }
  )

  api.nvim_buf_set_option(self.buf, "modifiable", true)
  api.nvim_buf_set_lines(self.buf, 0, -1, false, rendered_lines)
  api.nvim_buf_set_option(self.buf, "modifiable", false)

  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_set_config(self.win, win_config)
  else
    self.win = api.nvim_open_win(self.buf, false, win_config)
    api.nvim_win_set_option(self.win, "winblend", self.config.winblend)
    api.nvim_win_set_option(self.win, "wrap", self.config.wrap)
    api.nvim_win_set_option(self.win, "foldenable", false)
    api.nvim_win_set_option(self.win, "signcolumn", "no")
    api.nvim_win_set_option(self.win, "cursorline", false)
  end

  self:apply_highlights(contents)
  self.last_signature = { signature = signature, param = active_param }
end

---Hide the signature window
function SignatureWindow:hide()
  if self.win and api.nvim_win_is_valid(self.win) then
    api.nvim_win_close(self.win, true)
    self.win = nil
  end
  self.last_signature = nil
end

return SignatureWindow
