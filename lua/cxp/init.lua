local M = {}

local state = {
  code_win    = nil,
  input_buf   = nil,
  output_buf  = nil,
  compile_job = nil,
  run_job     = nil,
}

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

local function buf_valid(b) return b and vim.api.nvim_buf_is_valid(b) end

local function normalize_lines(lines)
  local result = {}
  for _, text in ipairs(lines or {}) do
    text = tostring(text):gsub('\r', '')
    for line in (text .. '\n'):gmatch('(.-)\n') do
      table.insert(result, line)
    end
  end
  while #result > 0 and result[#result] == '' do table.remove(result) end
  return result
end

local function write_output(lines)
  if not buf_valid(state.output_buf) then return end
  local clean = normalize_lines(lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = state.output_buf })
  vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, clean)
  vim.api.nvim_set_option_value('modifiable', false, { buf = state.output_buf })
end

local function kill_jobs()
  if state.run_job     then vim.fn.jobstop(state.run_job);     state.run_job = nil end
  if state.compile_job then vim.fn.jobstop(state.compile_job); state.compile_job = nil end
end

------------------------------------------------------------------------
-- TS runtime: bun >>> deno >>> tsx
------------------------------------------------------------------------

local _ts_runtime = nil
local function get_ts_runtime()
  if _ts_runtime then return _ts_runtime end
  if vim.fn.executable('bun')  == 1 then _ts_runtime = 'bun'
  elseif vim.fn.executable('deno') == 1 then _ts_runtime = 'deno'
  elseif vim.fn.executable('npx')  == 1 then _ts_runtime = 'npx'
  else _ts_runtime = 'node' end
  return _ts_runtime
end

local function ts_cmd(file)
  local rt = get_ts_runtime()
  if rt == 'bun'  then return { 'bun', 'run', file } end
  if rt == 'deno' then return { 'deno', 'run', '-A', file } end
  if rt == 'npx'  then return { 'npx', '-y', 'tsx', file } end
  return { 'node', file }
end

------------------------------------------------------------------------
-- format final output (FIXED SEPARATOR PLACEMENT)
------------------------------------------------------------------------

local function format_result(out, err, ecode, ms)
  local result = {}

  -- 1. Actual program output (stdout)
  for _, l in ipairs(out) do result[#result + 1] = l end

  -- 2. Separator immediately after program output
  result[#result + 1] = '--------------------------'

  -- 3. Stderr (if any, filtered)
  local clean_err = {}
  for _, l in ipairs(err) do
    if l ~= '' then clean_err[#clean_err + 1] = l end
  end
  if #clean_err > 0 then
    for _, l in ipairs(clean_err) do result[#result + 1] = l end
  end

  -- 4. Execution stats (exit code & time)
  result[#result + 1] = ''
  local signals = {
    [139] = 'SIGSEGV (segfault) — out of bounds / null ptr / stack overflow',
    [136] = 'SIGFPE — division by zero',
    [134] = 'SIGABRT — assert / double free / heap corruption',
    [137] = 'SIGKILL — OOM or timeout',
  }
  if signals[ecode] then
    result[#result + 1] = signals[ecode] .. '  |  ' .. ms .. ' ms'
  else
    result[#result + 1] = string.format('exit %d  |  %d ms', ecode, ms)
  end

  return result
end

------------------------------------------------------------------------
-- generic run
------------------------------------------------------------------------

local function run_cmd(cmd, input, label)
  write_output({ 'running (' .. label .. ')...' })
  local out, err = {}, {}
  local t0 = vim.loop.now()

  state.run_job = vim.fn.jobstart(cmd, {
    stdin           = 'pipe',
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then vim.list_extend(out, data) end
    end,
    on_stderr = function(_, data)
      if data then vim.list_extend(err, data) end
    end,
    on_exit = function(_, ecode)
      state.run_job = nil
      local ms = vim.loop.now() - t0
      vim.schedule(function()
        write_output(format_result(out, err, ecode, ms))
      end)
    end,
  })

  if state.run_job and state.run_job > 0 then
    vim.fn.chansend(state.run_job, input)
    vim.fn.chanclose(state.run_job, 'stdin')
  else
    write_output({ 'failed to start: ' .. table.concat(cmd, ' ') })
  end
end

------------------------------------------------------------------------
-- layout
------------------------------------------------------------------------

function M.toggle()
  if buf_valid(state.input_buf) then
    for _, name in ipairs({ 'Input', 'Output' }) do
      local b = vim.fn.bufnr(name)
      if b ~= -1 then vim.cmd('silent! bdelete! ' .. b) end
    end
    state.input_buf  = nil
    state.output_buf = nil
    return
  end

  state.code_win = vim.api.nvim_get_current_win()

  vim.cmd('botright ' .. math.floor(vim.o.columns * 0.3) .. 'vsplit')
  local right_win = vim.api.nvim_get_current_win()

  state.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.input_buf, 'Input')
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = state.input_buf })
  vim.api.nvim_win_set_buf(right_win, state.input_buf)

  vim.cmd('split')
  local out_win = vim.api.nvim_get_current_win()
  state.output_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.output_buf, 'Output')
  vim.api.nvim_set_option_value('buftype',    'nofile', { buf = state.output_buf })
  vim.api.nvim_set_option_value('modifiable', false,    { buf = state.output_buf })
  vim.api.nvim_win_set_buf(out_win, state.output_buf)

  vim.api.nvim_win_set_height(right_win, math.floor(vim.o.lines * 0.40))
  vim.api.nvim_set_current_win(state.code_win)
end

------------------------------------------------------------------------
-- run
------------------------------------------------------------------------

function M.run()
  if not buf_valid(state.input_buf) then M.toggle() end
  kill_jobs()

  local file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.code_win))
  local ext  = file:match('%.(%w+)$')
  local bin  = '/tmp/cp_' .. vim.fn.fnamemodify(file, ':t:r')

  if not ext then
    write_output({ 'no file extension detected' })
    return
  end

  vim.cmd('silent! write')

  local input = table.concat(
    vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false), '\n'
  )

  if ext == 'cpp' or ext == 'cc' or ext == 'c' then
    write_output({ 'compiling...' })
    local compiler = ext == 'c' and 'clang' or 'clang++'
    local cmd = ext == 'c'
      and { compiler, '-Wall', '-O2', '-o', bin, file }
      or  { compiler, '-Wall', '-O2', '-std=c++23', '-o', bin, file }

    local compile_err = {}

    state.compile_job = vim.fn.jobstart(cmd, {
      stderr_buffered = true,
      on_stderr = function(_, data)
        if data then
          for _, l in ipairs(data) do
            if l ~= '' then table.insert(compile_err, l) end
          end
        end
      end,
      on_exit = function(_, code)
        state.compile_job = nil
        if code ~= 0 then
          vim.schedule(function() write_output(compile_err) end)
          return
        end
        vim.schedule(function() run_cmd({ bin }, input, 'binary') end)
      end,
    })

  elseif ext == 'ts' then
    local rt = get_ts_runtime()
    run_cmd(ts_cmd(file), input, rt)

  elseif ext == 'js' then
    run_cmd({ 'node', file }, input, 'node')

  elseif ext == 'py' then
    run_cmd({ 'python3', file }, input, 'python3')

  else
    write_output({ 'unsupported: .' .. ext })
  end
end

------------------------------------------------------------------------
-- setup
------------------------------------------------------------------------

function M.setup()
  vim.keymap.set('n', '<leader>c', M.toggle, { desc = 'CP: toggle panel' })
  vim.keymap.set('n', '<leader>r', M.run,    { desc = 'CP: compile & run' })
end

return M
