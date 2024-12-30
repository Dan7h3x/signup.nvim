-- window.lua
local api = vim.api
local utils = require('signup.utils')

local M = {}

function M.create_floating_window(contents, config)
    local buf = api.nvim_create_buf(false, true)
    
    -- Set buffer options
    local buf_opts = {
        buftype = "nofile",
        bufhidden = "hide",
        swapfile = false,
        modifiable = true,
    }
    
    for opt, val in pairs(buf_opts) do
        vim.bo[buf][opt] = val
    end

    -- Calculate dimensions
    local width = math.min(
        math.max(#contents[1] + 4, config.min_width or 40),
        config.max_width or 80,
        vim.o.columns
    )
    local height = math.min(#contents, config.max_height or 10)

    -- Get cursor position
    local cursor_pos = api.nvim_win_get_cursor(0)
    local screen_pos = vim.fn.screenpos(0, cursor_pos[1], cursor_pos[2])
    
    -- Calculate position
    local row = screen_pos.row - 1
    local col = screen_pos.col

    -- Adjust for screen boundaries
    if row < 2 then
        row = screen_pos.row + 1
    end
    if col + width > vim.o.columns then
        col = vim.o.columns - width - 2
    end

    -- Create window options
    local win_opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = config.border or "rounded",
        zindex = 50
    }

    -- Create window
    local win = api.nvim_open_win(buf, false, win_opts)

    -- Set window options
    local win_config = {
        wrap = true,
        conceallevel = 2,
        foldenable = false,
        winblend = 0,
        winhighlight = table.concat({
            "Normal:SignatureHelpNormal",
            "FloatBorder:SignatureHelpBorder",
        }, ","),
    }

    for opt, val in pairs(win_config) do
        vim.wo[win][opt] = val
    end

    -- Set content
    api.nvim_buf_set_lines(buf, 0, -1, false, contents)

    return win, buf
end

function M.create_dock_window(contents, config)
    local buf = api.nvim_create_buf(false, true)
    
    -- Set buffer options
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    
    -- Calculate dimensions
    local width = math.min(config.max_width or 80, vim.o.columns - 4)
    local height = math.min(#contents, config.max_height or 10)
    
    -- Calculate position (bottom of screen)
    local row = vim.o.lines - height - 4
    local col = vim.o.columns - width - 2

    -- Create window options
    local win_opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = config.border or "rounded",
        zindex = 50,
        focusable = false,
    }

    -- Create window
    local win = api.nvim_open_win(buf, false, win_opts)

    -- Set window options
    vim.wo[win].wrap = true
    vim.wo[win].conceallevel = 2
    vim.wo[win].foldenable = false
    vim.wo[win].winhighlight = "Normal:SignatureHelpDock,FloatBorder:SignatureHelpBorder"

    -- Set content
    api.nvim_buf_set_lines(buf, 0, -1, false, contents)

    return win, buf
end

return M