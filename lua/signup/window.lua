-- window.lua
local api = vim.api
local utils = require('signup.utils')
local logger = require('signup.logger')

local M = {}

function M.create_window(contents, config)
    local buf = api.nvim_create_buf(false, true)
    
    -- Set buffer options
    local buf_opts = {
        buftype = "nofile",
        bufhidden = "hide",
        swapfile = false,
        filetype = "SignatureHelp",
        modifiable = true,
    }
    
    for opt, val in pairs(buf_opts) do
        vim.bo[buf][opt] = val
    end

    -- Calculate dimensions
    local width = math.min(
        math.max(#contents[1] + 4, config.ui.min_width),
        config.ui.max_width,
        vim.o.columns
    )
    local height = math.min(#contents, config.ui.max_height)

    -- Create window options
    local win_opts = {
        relative = "editor",
        width = width,
        height = height,
        style = "minimal",
        border = config.ui.border,
        zindex = config.ui.zindex,
    }

    -- Calculate position
    local pos = M.calculate_position(config)
    win_opts.row = pos.row
    win_opts.col = pos.col

    -- Create window
    local win = api.nvim_open_win(buf, false, win_opts)

    -- Set window options
    local win_config = {
        wrap = config.ui.wrap,
        foldenable = false,
        winblend = math.floor((1 - config.ui.opacity) * 100),
        winhighlight = table.concat({
            "Normal:SignatureHelpNormal",
            "FloatBorder:SignatureHelpBorder",
            "CursorLine:SignatureHelpCursorLine",
        }, ","),
        signcolumn = "no",
        cursorline = false,
        number = false,
        relativenumber = false,
        linebreak = true,
        breakindent = true,
        showbreak = "↪ ",
    }

    for opt, val in pairs(win_config) do
        vim.wo[win][opt] = val
    end

    return win, buf
end

return M