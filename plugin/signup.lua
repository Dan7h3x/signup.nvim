if vim.fn.has("nvim-0.8.0") == 0 then
  vim.api.nvim_err_writeln("signup.nvim requires at least nvim-0.8.0")
  return
end

-- Will be initialized in setup()
if vim.g.loaded_signup == 1 then
  return
end
vim.g.loaded_signup = 1 