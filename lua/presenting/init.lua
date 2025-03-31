--- *presenting.nvim*
--- *Presenting*
---
--- MIT License Copyright (c) 2024 Stefan Otte
---
--- ==============================================================================
---
--- Present your markdown, org-mode, or asciidoc files in a nice way,
--- i.e. directly in nvim.

-- Module definition ==========================================================
local Presenting = {}
local H = {}
Presenting._state = nil

--- Module setup
---
---@param config table|nil
---@usage `require('presenting').setup({})`
Presenting.setup = function(config)
  _G.Presenting = Presenting
  config = H.setup_config(config)
  H.apply_config(config)

  vim.api.nvim_create_user_command("Presenting", Presenting.toggle, { nargs = "*" })
  vim.api.nvim_create_user_command("PresentingDevMode", Presenting.dev_mode, {})

  local presenting_autocmd_group_id = vim.api.nvim_create_augroup("PresentingAutoGroup", {})
  vim.api.nvim_create_autocmd("WinResized", {
    group = presenting_autocmd_group_id,
    callback = function() Presenting.resize() end,
  })
end

--- Module config
---
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
Presenting.config = {
  options = {
    -- The width of the slide buffer.
    width = 60,
  },

  slide_separator = {
    -- Slide separators for different filetypes.
    -- You can add your own or oberwrite existing ones.
    -- Note: separators are lua patterns, not regexes.
    markdown = "^# ",
    org = "^*+ ",
    adoc = "^==+ ",
    asciidoctor = "^==+ ",
  },
  step_separator = {
    -- Step separators.
    markdown = "^## ",
  },

  -- Keep the separator, useful if you're parsing based on headings.
  -- If you want to parse on a non-heading separator, e.g. `---` set this to false.
  keep_separator = true,
  keymaps = {
    -- These are local mappings for the open slide buffer.
    -- Disable existing keymaps by setting them to `nil`.
    -- Add your own keymaps as you desire.
    ["n"] = function() Presenting.next_step() end,
    ["p"] = function() Presenting.prev_step() end,
    ["q"] = function() Presenting.quit() end,
    ["f"] = function() Presenting.first() end,
    ["l"] = function() Presenting.last() end,
    ["t"] = function() Presenting.top() end,
    ["b"] = function() Presenting.bottom() end,
    ["<CR>"] = function() Presenting.next_step() end,
    ["<BS>"] = function() Presenting.prev_step() end,
  },
  -- A function that configures the slide buffer.
  -- If you want custom settings write your own function that accepts a buffer id as argument.
  configure_slide_buffer = function(buf) H.configure_slide_buffer(buf) end,
}
--minidoc_afterlines_end

--- ==============================================================================
--- # Core functionality

--- Toggle presenting mode on/off for the current buffer.
Presenting.toggle = function(cmd_opts)
  if H.in_presenting_mode() then
    Presenting.quit()
  else
    Presenting.start(cmd_opts.fargs[1], cmd_opts.fargs[2])
  end
end

--- Start presenting the current buffer.
---@param slide_sep string|nil Overwrite the default slide_separator if specified.
---@param step_sep string|nil Overwrite the default step_separator if specified.
Presenting.start = function(slide_sep, step_sep)
  if H.in_presenting_mode() then
    vim.notify("Already presenting")
    return
  end

  local filetype = vim.bo.filetype
  slide_sep = slide_sep or Presenting.config.slide_separator[filetype]
  step_sep = step_sep or Presenting.config.step_separator[filetype]

  if slide_sep == nil or step_sep == nil then
    vim.notify(
      "presenting.nvim does not support filetype "
        .. filetype
        .. ". You can specify slide and step separators manually: e.g. Presenting.start('---slide', '---step')"
    )
    return
  end

  Presenting._state = {
    filetype = filetype,
    slides = {},
    slide = 1,
    step = 1,
    n_slides = nil,
    slide_buf = nil,
    slide_win = nil,
    background_buf = nil,
    background_win = nil,
    footer_buf = nil,
    footer_win = nil,
    view = nil,
  }

  -- content of slides
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  Presenting._state.slides =
    H.parse_slides(lines, slide_sep, step_sep, Presenting.config.keep_separator)
  Presenting._state.n_slides = #Presenting._state.slides

  H.create_slide_view(Presenting._state)
end

--- Quit the current presentation and go back to the normal buffer.
--- By default this is mapped to `q`.
Presenting.quit = function()
  if not H.in_presenting_mode() then
    vim.notify("Not in presenting mode")
    return
  end

  vim.api.nvim_buf_delete(Presenting._state.slide_buf, { force = true })
  -- vim.api.nvim_win_close(Presenting._state.slide_win, true)

  vim.api.nvim_buf_delete(Presenting._state.footer_buf, { force = true })
  -- vim.api.nvim_win_close(Presenting._state.footer_win, true)

  vim.api.nvim_buf_delete(Presenting._state.background_buf, { force = true })
  -- vim.api.nvim_win_close(Presenting._state.background_win, true)

  Presenting._state = nil
end

--- Go to the next slide.
--- By default this is mapped to `<CR>` and `n`.
Presenting.next_step = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end

  local num_steps = #Presenting._state.slides[Presenting._state.slide].steps
  local next_step = Presenting._state.step + 1
  local next_slide = Presenting._state.slide
  if next_step > num_steps then
    next_slide = math.min(next_slide + 1, Presenting._state.n_slides)
    if next_slide ~= Presenting._state.slide then
      next_step = 1
    else
      next_step = next_step - 1
    end
  end

  H.set_slide_content(Presenting._state, next_slide, next_step)
end

--- Go to the previous slide.
--- By default this is mapped to `<BS>` and `p`.
Presenting.prev_step = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end

  local next_step = Presenting._state.step - 1
  local next_slide = Presenting._state.slide
  if next_step < 1 then
    next_slide = math.max(next_slide - 1, 1)
    if next_slide ~= Presenting._state.slide then
      next_step = #Presenting._state.slides[next_slide].steps
    else
      next_step = next_step + 1
    end
  end

  H.set_slide_content(Presenting._state, next_slide, next_step)
end

-- Go to the beginning of the current slide.
Presenting.top = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end

  H.set_slide_content(Presenting._state, Presenting._state.slide, 1)
end

-- Go to the end of the current slide.
Presenting.bottom = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end

  local step = #Presenting._state.slides[Presenting._state.slide].steps
  H.set_slide_content(Presenting._state, Presenting._state.slide, step)
end

--- Go to the first slide.
--- By default this is mapped to `f`.
Presenting.first = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end
  H.set_slide_content(Presenting._state, 1, 1)
end

--- Go to the last slide.
--- By default this is mapped to `l`.
Presenting.last = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end

  local step = #Presenting._state.slides[Presenting._state.n_slides].steps
  H.set_slide_content(Presenting._state, Presenting._state.n_slides, step)
end

---Resize the slide window.
Presenting.resize = function()
  if not H.in_presenting_mode() then return end
  if
    (Presenting._state.background_win == nil)
    or (Presenting._state.slide_win == nil)
    or (Presenting._state.footer_win == nil)
  then
    return
  end

  local window_config = H.get_win_configs()
  vim.api.nvim_win_set_config(Presenting._state.background_win, window_config.background)
  vim.api.nvim_win_set_config(Presenting._state.footer_win, window_config.footer)
  vim.api.nvim_win_set_config(Presenting._state.slide_win, window_config.slide)
end

Presenting.dev_mode = function()
  package.loaded["presenting"] = nil
  _G.Presenting = nil
  require("presenting").start()
end

--- ==============================================================================
--- Internal Helper
--- As end user you should not need to use these functions.
---@private
H.default_config = vim.deepcopy(Presenting.config)

---@param config table|nil
---@private
H.setup_config = function(config)
  vim.validate({ config = { config, "table", true } })
  -- TODO: validate some more
  return vim.tbl_deep_extend("force", vim.deepcopy(H.default_config), config or {})
end

---@param config table
---@private
H.apply_config = function(config)
  -- nothing to do right now
  Presenting.config = config
end

---@return table
---@private
H.get_win_configs = function()
  local slide_width = Presenting.config.options.width
  local width = vim.api.nvim_get_option_value("columns", {})
  local height = vim.api.nvim_get_option_value("lines", {})
  local offset = math.ceil((width - slide_width) / 2)
  return {
    background = {
      style = "minimal",
      relative = "editor",
      focusable = false,
      width = width,
      height = height,
      row = 0,
      col = 0,
      zindex = 1,
    },
    slide = {
      style = "minimal",
      relative = "editor",
      width = slide_width,
      height = height - 5,
      row = 0,
      col = offset,
      zindex = 10,
    },
    footer = {
      style = "minimal",
      relative = "editor",
      width = slide_width,
      height = 1,
      row = height - 1,
      col = offset,
      focusable = false,
      zindex = 2,
    },
  }
end

---@param state table
---@private
H.create_slide_view = function(state)
  local window_config = H.get_win_configs()

  state.background_buf = vim.api.nvim_create_buf(false, true)
  state.background_win =
    vim.api.nvim_open_win(state.background_buf, false, window_config.background)

  -- TODO: maybe just use vims statusline instead of my custom footer :)
  state.footer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, { "presenting.nvim" })
  state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, window_config.footer)

  state.slide_buf = vim.api.nvim_create_buf(false, true)
  state.slide_win = vim.api.nvim_open_win(state.slide_buf, true, window_config.slide)
  Presenting.config.configure_slide_buffer(state.slide_buf)
  H.set_slide_keymaps(state.slide_buf, Presenting.config.keymaps)

  H.set_slide_content(state, 1, 1)
end

---@param lines table
---@param slide_sep string
---@param step_sep string
---@return table
---@private
H.parse_slides = function(lines, slide_sep, step_sep, keep_separator)
  local slides = {}
  local slide = {
    steps = {},
  }
  local step = {}

  for _, line in pairs(lines) do
    if line:match(slide_sep) then

      if #slide.steps > 0 or #step > 0 then
        table.insert(slide.steps, step)
        table.insert(slides, slide)
      end
      -- create new slide & step
      slide = {
        steps = {},
      }
      step = {}
      if keep_separator then table.insert(step, line) end
    elseif line:match(step_sep) then
      if #step > 0 then
        table.insert(slide.steps, step)
        -- create new step
        step = {}
        if keep_separator then table.insert(step, line) end
      end
    else
      table.insert(step, line)
    end
  end

  table.insert(slide.steps, step)
  table.insert(slides, slide)

  return slides
end

---@param buf integer
---@private
H.configure_slide_buffer = function(buf)
  -- TODO: make this configurable via config
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("filetype", Presenting._state.filetype, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param state table
---@param slide integer
---@param step integer
---@private
H.set_slide_content = function(state, slide, step)
  local orig_modifiable = vim.api.nvim_get_option_value("modifiable", {buf=state.slide_buf})
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.slide_buf })
  state.slide = slide
  state.step = step
  local lines = {}
  for i = 1, state.step do
    for _, l in ipairs(state.slides[state.slide].steps[i]) do
      lines[#lines + 1] = l
    end
  end
  vim.api.nvim_buf_set_lines(state.slide_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", orig_modifiable, { buf = state.slide_buf })

  local footer_text = "presenting.nvim | " .. state.slide .. "/" .. state.n_slides
  vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, { footer_text })
end

---@param buf integer
---@param mappings table
---@private
H.set_slide_keymaps = function(buf, mappings)
  for k, v in pairs(mappings) do
    if type(v) == "string" then
      local cmd = ":lua require('presenting')." .. v .. "()<CR>"
      vim.api.nvim_buf_set_keymap(buf, "n", k, cmd, { noremap = true, silent = true })
    elseif type(v) == "function" then
      vim.api.nvim_buf_set_keymap(buf, "n", k, "", { callback = v, noremap = true, silent = true })
    end
    -- no keymap on nil 🤷
  end
end

---@return boolean
H.in_presenting_mode = function() return Presenting._state ~= nil end

return Presenting
