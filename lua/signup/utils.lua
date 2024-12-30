-- utils.lua
local M = {}

-- Window validation helper
function M.is_valid_window(win)
    return win and vim.api.nvim_win_is_valid(win)
end

-- Buffer validation helper
function M.is_valid_buffer(buf)
    return buf and vim.api.nvim_buf_is_valid(buf)
end

-- Enhanced debounce function with timer cleanup
function M.debounce(fn, ms)
    local timer = vim.loop.new_timer()
    return function(...)
        local args = { ... }
        timer:stop()
        timer:start(ms, 0, function()
            vim.schedule(function()
                fn(unpack(args))
            end)
        end)
    end
end

-- Safe function call wrapper with error handling
function M.safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        vim.notify("Error in signature help: " .. result, vim.log.levels.ERROR)
        return nil
    end
    return result
end

return M