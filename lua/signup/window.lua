-- window.lua
local api = vim.api
local utils = require('signup.utils')

local M = {}

-- Calculate optimal window position
local function calculate_position(config)
    local cursor_pos = utils.get_cursor_relative_pos()
    local editor_height = vim.o.lines
    local editor_width = vim.o.columns
    
    -- Check for completion menu position
    local pum_pos = vim.fn.pum_getpos()
    local has_pum = not vim.tbl_isempty(pum_pos)
    
    local row = cursor_pos.row
    local col = cursor_pos.col

    -- Adjust position if completion menu is visible
    if has_pum then
        if pum_pos.row < cursor_pos.row then
            -- Completion above cursor, place window below
            row = row + 1
        else
            -- Completion below cursor, place window above
            row = row - config.ui.max_height - 2
        end
    else
        -- Default positioning
        if row > editor_height / 2 then
            row = row - config.ui.max_height - 2
        else
            row = row + 1
        end
    end

    -- Ensure window fits horizontally
    if col + config.ui.max_width > editor_width then
        col = editor_width - config.ui.max_width - 2
    end

    return row, col
end

function M.create_floating_window(contents, config)
    local buf = api.nvim_create_buf(false, true)
    
    -- Set buffer options
    local buf_opts = {
        buftype = "nofile",
        bufhidden = "hide",
        swapfile = false,
        modifiable = true,
        filetype = "SignatureHelp"
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

    -- Get optimal position
    local row, col = calculate_position(config)

    -- Create window options
    local win_opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = config.ui.border,
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
            "CursorLine:SignatureHelpActiveLine",
        }, ","),
        signcolumn = "no",
        cursorline = false,
        number = false,
        relativenumber = false
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
    vim.bo[buf].filetype = "SignatureHelp"
    
    -- Calculate dimensions
    local width = math.min(config.ui.max_width, vim.o.columns - 4)
    local height = math.min(#contents, config.ui.max_height)
    
    -- Calculate position based on dock position
    local row = config.behavior.dock_position == "top" and 1 or (vim.o.lines - height - 4)
    local col = vim.o.columns - width - 2

    -- Create window options
    local win_opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = config.ui.border,
        zindex = 50,
        focusable = false,
    }

    -- Create window
    local win = api.nvim_open_win(buf, false, win_opts)

    -- Set window options
    local win_config = {
        wrap = true,
        conceallevel = 2,
        foldenable = false,
        winblend = 0,
        winhighlight = "Normal:SignatureHelpDock,FloatBorder:SignatureHelpBorder",
        signcolumn = "no",
        cursorline = false,
        number = false,
        relativenumber = false
    }

    for opt, val in pairs(win_config) do
        vim.wo[win][opt] = val
    end

    -- Set content
    api.nvim_buf_set_lines(buf, 0, -1, false, contents)

    -- Add separator line
    if config.behavior.dock_position == "top" then
        api.nvim_buf_set_lines(buf, -1, -1, false, {string.rep("─", width)})
    else
        api.nvim_buf_set_lines(buf, 0, 0, false, {string.rep("─", width)})
    end

    return win, buf
end

-- Update window position
function M.update_window_position(win, config)
    if not utils.is_valid_window(win) then return end
    
    local row, col = calculate_position(config)
    local win_config = vim.api.nvim_win_get_config(win)
    
    win_config.row = row
    win_config.col = col
    
    vim.api.nvim_win_set_config(win, win_config)
end

return M