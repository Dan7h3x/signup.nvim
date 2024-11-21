local M = {}

---@param ms number
---@param fn function
function M.debounce(ms, fn)
  local timer = vim.loop.new_timer()
  return function(...)
    local args = { ... }
    timer:start(ms, 0, function()
      timer:stop()
      vim.schedule(function()
        fn(unpack(args))
      end)
    end)
  end
end

---@param fn function
function M.protect(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      vim.notify("signup.nvim error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

---@param buf number
---@return string
function M.get_current_char(buf)
  local current_win = vim.api.nvim_get_current_win()
  local win = buf == vim.api.nvim_win_get_buf(current_win) and current_win or vim.fn.bufwinid(buf)
  local cursor = vim.api.nvim_win_get_cursor(win == -1 and 0 or win)
  local row = cursor[1] - 1
  local col = cursor[2]
  local _, lines = pcall(vim.api.nvim_buf_get_text, buf, row, 0, row, col, {})
  local line = vim.trim(lines and lines[1] or "")
  return line:sub(-1, -1)
end

---@param text string|table
---@return string[]
function M.split_lines(text)
  if type(text) == "table" then
    text = text.value or ""
  end
  return vim.split(text, "\n")
end

return M

