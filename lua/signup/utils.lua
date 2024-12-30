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

-- Check for completion menu visibility
function M.is_completion_visible()
    -- Check nvim-cmp
    local has_cmp, cmp = pcall(require, "cmp")
    if has_cmp and cmp.visible() then
        return true
    end

    -- Check blink.cmp
    local has_blink, blink = pcall(require, "blink.cmp")
    if has_blink and blink.visible() then
        return true
    end

    -- Check built-in completion
    return vim.fn.pumvisible() == 1
end

-- Get cursor position relative to window
function M.get_cursor_relative_pos()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local screen_pos = vim.fn.screenpos(0, cursor_pos[1], cursor_pos[2])
    local win_pos = vim.api.nvim_win_get_position(0)
    
    return {
        row = screen_pos.row - win_pos[1],
        col = screen_pos.col - win_pos[2]
    }
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