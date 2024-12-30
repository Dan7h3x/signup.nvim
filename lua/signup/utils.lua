-- utils.lua
local M = {}

function M.is_valid_window(win)
    return win and vim.api.nvim_win_is_valid(win)
end

function M.is_valid_buffer(buf)
    return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.debounce(fn, ms)
    local timer = vim.loop.new_timer()
    return function(...)
        local args = {...}
        timer:stop()
        timer:start(ms, 0, function()
            vim.schedule(function()
                fn(unpack(args))
            end)
        end)
    end
end

function M.throttle(fn, ms)
    local timer = vim.loop.new_timer()
    local running = false
    return function(...)
        if not running then
            running = true
            fn(...)
            timer:start(ms, 0, function()
                running = false
            end)
        end
    end
end

function M.safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if not ok then
        vim.notify("Error in signup.nvim: " .. result, vim.log.levels.ERROR)
        return nil
    end
    return result
end

return M