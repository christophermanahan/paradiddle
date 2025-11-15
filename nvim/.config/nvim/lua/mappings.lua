require "nvchad.mappings"
local wk = require "which-key"
local map = vim.keymap.set

-- deprecated
-- map("n", "<C-h>", "<cmd>TmuxNavigateLeft<CR>")
-- map("n", "<C-l>", "<cmd>TmuxNavigateRight<CR>")
-- map("n", "<C-j>", "<cmd>TmuxNavigateDown<CR>")
-- map("n", "<C-k>", "<cmd>TmuxNavigateUp<CR>")

map("n", "<C-h>", require("smart-splits").move_cursor_left)
map("n", "<C-j>", require("smart-splits").move_cursor_down)
map("n", "<C-k>", require("smart-splits").move_cursor_up)
map("n", "<C-l>", require("smart-splits").move_cursor_right)

-- ============================================================================
-- Terminal Scrolling: CTRL+q Handler
-- ============================================================================
-- Cache for tmux process checks (reduces system call overhead)
_G.tmux_check_cache = _G.tmux_check_cache or {}

-- Track the tmux terminal buffer number (since term_id isn't set reliably)
_G.tmux_terminal_buffer = _G.tmux_terminal_buffer or nil

-- Clean up tracking when tmux terminal buffer is deleted
vim.api.nvim_create_autocmd("BufDelete", {
  callback = function(args)
    if _G.tmux_terminal_buffer and args.buf == _G.tmux_terminal_buffer then
      _G.tmux_terminal_buffer = nil
    end
  end,
})

-- Check if tmux is actually running in this terminal job
-- Uses 500ms cache to avoid repeated system calls
local function is_tmux_alive(job_id)
  local now = vim.loop.now()
  local cache_entry = _G.tmux_check_cache[job_id]

  -- Return cached result if less than 500ms old
  if cache_entry and (now - cache_entry.time) < 500 then
    return cache_entry.alive
  end

  -- Check if tmux process exists as child of terminal
  local pid = vim.fn.jobpid(job_id)
  if not pid or pid == -1 then
    _G.tmux_check_cache[job_id] = { time = now, alive = false }
    return false
  end

  -- Use pgrep to find child processes, then check if any are tmux
  local output = vim.fn.system("pgrep -P " .. pid .. " | xargs ps -o comm= 2>/dev/null")
  local alive = output and output:match("tmux") ~= nil

  _G.tmux_check_cache[job_id] = { time = now, alive = alive }
  return alive
end

-- Terminal mode: CTRL+q for scrolling
-- Non-tmux terminals: Enter Neovim normal mode (same as NvChad's CTRL+x behavior)
-- Tmux terminal: Send CTRL+f [ to enter tmux copy-mode (native tmux scrolling)
map("t", "<C-q>", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local chan = vim.b[bufnr].terminal_job_id

  if not chan then
    vim.cmd("stopinsert")
    return
  end

  -- Hybrid approach: Buffer match + process check
  -- Step 1: Check if this buffer is the tracked tmux terminal buffer
  local is_tmux_terminal = (_G.tmux_terminal_buffer and bufnr == _G.tmux_terminal_buffer)

  if is_tmux_terminal then
    -- Step 2: Verify tmux is actually running (handles exit/crash/stale state)
    if is_tmux_alive(chan) then
      -- Tmux is alive: send CTRL+f [ (tmux's native copy-mode key sequence)
      -- This provides full scrollback buffer access with all tmux keybindings
      vim.api.nvim_chan_send(chan, "\x06[") -- \x06 is CTRL+f, then literal [
      return
    end
  end

  -- Default: enter Neovim normal mode for scrolling (NvChad default behavior)
  vim.cmd("stopinsert") -- Equivalent to <C-\><C-N>
end, { desc = "Terminal scrolling (tmux copy-mode or nvim normal mode)" })

vim.keymap.del({ "n", "t" }, "<A-v>")
vim.keymap.del({ "n", "t" }, "<A-i>")
vim.keymap.del({ "n", "t" }, "<A-h>")

-- ============================================================================
-- Multi-Instance Terminal System
-- ============================================================================

-- Base offsets for each terminal type (used as starting position)
local BASE_OFFSETS = {
  claude_term = { row = 0.02, col = 0.02 },
  tmux_term = { row = 0.03, col = 0.03 },      -- Note: actual ID is floatTerm_<pid>
  k9s_term = { row = 0.04, col = 0.04 },
  lazygit_term = { row = 0.05, col = 0.05 },
  openai_term = { row = 0.06, col = 0.06 },
  lazydockerTerm = { row = 0.07, col = 0.07 },
  posting_term = { row = 0.08, col = 0.08 },
  e1sTerm = { row = 0.09, col = 0.09 },
}

-- Calculate diagonal offset for instance N of a terminal type
-- instance_index: 0-based index (0 = first instance, 1 = second, etc.)
-- Returns: { row = float, col = float }
local function calculate_instance_offset(term_type, instance_index)
  local base = BASE_OFFSETS[term_type]
  if not base then
    -- Fallback for unknown types (shouldn't happen)
    base = { row = 0.02, col = 0.02 }
  end

  -- ~7 pixels diagonal offset per instance (0.007 ≈ 7px on typical screen)
  local pixel_offset = 0.007 * instance_index

  return {
    row = base.row + pixel_offset,
    col = base.col + pixel_offset,
  }
end

-- Instance tracking registry
-- Structure: terminal_instances[term_type] = {
--   instances = { { id, bufnr, started, offset_index }, ... },
--   focused_index = number,
--   visible = boolean
-- }
if not _G.terminal_instances then
  _G.terminal_instances = {}
end

-- Track which terminal TYPE is currently in foreground (e.g., "claude_term", "k9s_term")
_G.active_terminal_type = _G.active_terminal_type or nil

-- Backward compatibility: keep existing tracking for migration
_G.foreground_terminal = _G.foreground_terminal or nil
if not _G.terminal_buffers then
  _G.terminal_buffers = {}
end

-- Normalize term_type: handle special cases like floatTerm_<pid> → tmux_term
-- This allows us to group tmux instances under a single type despite dynamic IDs
local function normalize_term_type(term_id)
  if term_id:match("^floatTerm_") then
    return "tmux_term"
  end
  return term_id
end

-- Get base term_type from instance ID
-- Example: "claude_term_2" → "claude_term", "floatTerm_12345" → "tmux_term"
local function get_base_term_type(instance_id)
  -- Handle tmux special case first
  if instance_id:match("^floatTerm_") then
    return "tmux_term"
  end

  -- For other types, strip "_N" suffix if present
  local base = instance_id:match("^(.-)_%d+$")
  return base or instance_id
end

-- Get or create registry entry for a terminal type
-- Returns the registry entry (table with instances, focused_index, visible)
local function get_or_create_registry(term_type)
  if not _G.terminal_instances[term_type] then
    _G.terminal_instances[term_type] = {
      instances = {},
      focused_index = 0,
      visible = false,
    }
  end
  return _G.terminal_instances[term_type]
end

-- Find a terminal window by term_id
-- Returns: window ID, buffer number (or nil, nil if not found)
local function find_term_window(term_id)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      local buf_term_id = vim.b[buf].term_id
      -- Match exact term_id or term_id pattern (for tmux which has unique per-nvim-instance IDs)
      if buf_term_id == term_id or (buf_term_id and buf_term_id:match("^" .. term_id)) then
        return win, buf
      end
    end
  end
  return nil, nil
end

-- Check if a terminal buffer exists (even if window is closed)
-- Returns: buffer number or nil
local function find_term_buffer(term_id)
  -- First check if we have it tracked
  if _G.terminal_buffers[term_id] then
    local buf = _G.terminal_buffers[term_id]
    if vim.api.nvim_buf_is_valid(buf) then
      return buf
    else
      -- Buffer was deleted, clean up tracking
      _G.terminal_buffers[term_id] = nil
    end
  end

  -- Search all buffers as fallback
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
      local buf_term_id = vim.b[buf].term_id
      if buf_term_id == term_id or (buf_term_id and buf_term_id:match("^" .. term_id)) then
        _G.terminal_buffers[term_id] = buf
        return buf
      end
    end
  end
  return nil
end

-- Smart toggle: if target terminal exists but isn't foreground, hide foreground first
-- Returns: true if should proceed with toggle, false if already handled
local function prepare_toggle(term_id)
  local target_win, target_buf = find_term_window(term_id)

  -- If window doesn't exist, check if buffer exists
  if not target_buf then
    target_buf = find_term_buffer(term_id)
  end

  local current_buf = vim.api.nvim_get_current_buf()

  -- Case 1: Target terminal doesn't exist (neither window nor buffer) → Will open it
  if not target_win and not target_buf then
    _G.foreground_terminal = term_id
    return true  -- Proceed with toggle (opens it)
  end

  -- Case 2: Target terminal is already focused → Will close it
  if current_buf == target_buf then
    _G.foreground_terminal = nil
    return true  -- Proceed with toggle (closes it)
  end

  -- Case 3: Target terminal exists but isn't focused (hidden behind another terminal)
  -- Close the foreground terminal first to reveal the target
  if _G.foreground_terminal and _G.foreground_terminal ~= term_id then
    local fg_win, _ = find_term_window(_G.foreground_terminal)
    if fg_win then
      -- Close the foreground terminal window (reveals target underneath)
      vim.api.nvim_win_close(fg_win, false)
      _G.foreground_terminal = term_id
      -- Focus the now-visible target terminal after a brief delay
      vim.defer_fn(function()
        local tw, _ = find_term_window(term_id)
        if tw then
          vim.api.nvim_set_current_win(tw)
          vim.cmd("startinsert")
        end
      end, 50)
      return false  -- Don't toggle, we already handled it
    end
  end

  -- Case 4: No foreground terminal conflict, proceed normally
  _G.foreground_terminal = term_id
  return true  -- Proceed with toggle
end

-- ============================================================================
-- Multi-Instance Terminal Functions
-- ============================================================================

-- Auto-start a command in a terminal instance
-- instance_id: The terminal instance ID (e.g., "claude_term_1")
-- command: The shell command to execute (e.g., "claude" or the session prompt script)
-- bufnr: The buffer number of the terminal (captured immediately after toggle)
local function auto_start_instance(instance_id, command, bufnr)
  vim.defer_fn(function()
    -- Verify this is still a terminal buffer
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal" then
      -- Get the job_id from the buffer
      local success, job_id = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")

      if success and job_id then
        -- Send the command to the terminal
        vim.api.nvim_chan_send(job_id, command .. "\n")

        -- Mark this instance as started in the registry
        local term_type = get_base_term_type(instance_id)
        local registry = get_or_create_registry(term_type)
        for _, instance in ipairs(registry.instances) do
          if instance.id == instance_id then
            instance.started = true
            break
          end
        end
      else
        vim.notify("Failed to get terminal job_id for " .. instance_id, vim.log.levels.WARN)
      end
    else
      vim.notify("Buffer is not a valid terminal for " .. instance_id, vim.log.levels.WARN)
    end
  end, 200)
end

-- Get default configuration for a terminal type
-- Returns: { width, height, title, command }
local function get_default_config(term_type)
  local configs = {
    claude_term = {
      width = 0.85,
      height = 0.85,
      title = "Claude Code 🤖",
      command = [[bash -c '
# Create a temp script with proper stdin access
cat > /tmp/claude_session_prompt_$$.sh << "SCRIPT_END"
#!/bin/bash
exec < /dev/tty
if [ -d .claude ] && [ "$(ls -A .claude 2>/dev/null)" ]; then
  echo "📂 Previous Claude session detected in this directory"
  echo ""
  echo "Would you like to:"
  echo "  [c] Continue previous session"
  echo "  [f] Start fresh"
  echo ""
  read -r -p "Your choice (c/f): " choice
  echo ""
  case "$choice" in
    c|C)
      echo "▶ Continuing previous session..."
      sleep 0.2
      exec claude -c
      ;;
    f|F)
      echo "▶ Starting fresh session..."
      sleep 0.2
      exec claude
      ;;
    *)
      echo "▶ Invalid choice, starting fresh session..."
      sleep 0.2
      exec claude
      ;;
  esac
else
  clear
  exec claude
fi
SCRIPT_END
chmod +x /tmp/claude_session_prompt_$$.sh
exec /tmp/claude_session_prompt_$$.sh
']],
    },
    tmux_term = {
      width = 0.85,
      height = 0.85,
      title = "multiflexing 💪",
      command = nil,  -- tmux needs special handling with nvim PID
    },
    k9s_term = {
      width = 0.85,
      height = 0.85,
      title = "k9s 🚀",
      command = nil,  -- k9s needs cluster selection prompt
    },
    lazygit_term = {
      width = 0.85,
      height = 0.85,
      title = "Lazygit 🦊",
      command = "lazygit",
    },
    openai_term = {
      width = 0.85,
      height = 0.85,
      title = "OpenAI Codex 🧠",
      command = "codex",
    },
    lazydockerTerm = {
      width = 0.85,
      height = 0.85,
      title = "Lazydocker 🐳",
      command = "lazydocker",
    },
    posting_term = {
      width = 0.85,
      height = 0.85,
      title = "Posting 📮",
      command = "posting",
    },
    e1sTerm = {
      width = 0.85,
      height = 0.85,
      title = "e1s ⚡",
      command = nil,  -- e1s needs profile/region selection
    },
  }

  return configs[term_type] or {
    width = 0.85,
    height = 0.85,
    title = "Terminal",
    command = nil,
  }
end

-- Spawn a new instance of a terminal type
-- term_type: The base terminal type (e.g., "claude_term", "k9s_term")
-- config: Configuration table { width, height, title, command } (optional, uses defaults if nil)
local function spawn_new_instance(term_type, config)
  -- Normalize term_type (handle floatTerm_<pid> → tmux_term)
  local normalized_type = normalize_term_type(term_type)

  -- Get or create registry for this type
  local registry = get_or_create_registry(normalized_type)

  -- Calculate next instance ID and offset
  local next_index = #registry.instances
  local instance_id

  -- Special handling for tmux (uses floatTerm_<pid> pattern)
  if normalized_type == "tmux_term" then
    local nvim_pid = vim.fn.getpid()
    -- For tmux, we use the nvim PID in the instance ID to keep them unique per nvim instance
    -- But for multi-instance, we append _N
    instance_id = "floatTerm_" .. nvim_pid .. "_" .. (next_index + 1)
  else
    instance_id = normalized_type .. "_" .. (next_index + 1)
  end

  local offset = calculate_instance_offset(normalized_type, next_index)

  -- Use provided config or get defaults
  local cfg = config or get_default_config(normalized_type)

  -- Create terminal with NvChad
  local term = require("nvchad.term")
  term.toggle {
    pos = "float",
    id = instance_id,
    float_opts = {
      row = offset.row,
      col = offset.col,
      width = cfg.width,
      height = cfg.height,
      title = cfg.title .. " (" .. (next_index + 1) .. ")",  -- Add instance number to title
      title_pos = "center",
    }
  }

  -- Register instance
  local bufnr = vim.api.nvim_get_current_buf()
  table.insert(registry.instances, {
    id = instance_id,
    bufnr = bufnr,
    started = false,
    offset_index = next_index,
  })

  -- Update focus and visibility
  registry.focused_index = next_index
  registry.visible = true
  _G.active_terminal_type = normalized_type

  -- Auto-start if config provides command
  if cfg.command then
    auto_start_instance(instance_id, cfg.command, bufnr)
  end

  vim.notify("Spawned " .. normalized_type .. " instance " .. (next_index + 1), vim.log.levels.INFO)
end

-- ============================================================================
-- Phase 3: Group Toggle - Show/hide ALL instances of a terminal type
-- ============================================================================

-- Toggle all instances of a terminal type (show/hide as a group)
-- If no instances exist, spawns the first one
-- term_type: normalized type (e.g., "claude_term", "k9s_term")
local function toggle_terminal_group(term_type)
  local registry = _G.terminal_instances[term_type]

  -- Case 1: No instances exist yet → spawn first instance
  if not registry or #registry.instances == 0 then
    spawn_new_instance(term_type)
    return
  end

  local currently_visible = registry.visible

  if currently_visible then
    -- HIDE: Close all windows for this type
    for _, instance in ipairs(registry.instances) do
      local win, _ = find_term_window(instance.id)
      if win then
        vim.api.nvim_win_close(win, false)
      end
    end
    registry.visible = false
    _G.active_terminal_type = nil
  else
    -- SHOW: Open all instances with their calculated offsets
    -- First, hide any OTHER terminal type that's currently visible
    if _G.active_terminal_type and _G.active_terminal_type ~= term_type then
      toggle_terminal_group(_G.active_terminal_type)  -- Hide other type
    end

    -- Show all instances of this type
    local term = require("nvchad.term")
    for i, instance in ipairs(registry.instances) do
      local offset = calculate_instance_offset(term_type, instance.offset_index)
      local cfg = get_default_config(term_type)

      term.toggle {
        pos = "float",
        id = instance.id,
        float_opts = {
          row = offset.row,
          col = offset.col,
          width = cfg.width,
          height = cfg.height,
          title = cfg.title .. " (" .. (i) .. ")",  -- Show instance number
          title_pos = "center",
        }
      }
    end

    registry.visible = true
    _G.active_terminal_type = term_type

    -- Focus the last focused instance
    if registry.focused_index and registry.focused_index < #registry.instances then
      local focused_instance = registry.instances[registry.focused_index + 1]  -- Lua 1-indexed
      if focused_instance then
        local win, _ = find_term_window(focused_instance.id)
        if win then
          vim.api.nvim_set_current_win(win)
          vim.cmd("startinsert")
        end
      end
    end
  end
end

-- ============================================================================
-- Phase 4: Cycling Mechanism - Navigate between instances
-- ============================================================================

-- Bring a specific instance to the front (focus)
-- Uses close/reopen trick since NvChad doesn't support native z-order
-- term_type: normalized type (e.g., "claude_term")
-- index: 0-based instance index
local function focus_instance(term_type, index)
  local registry = _G.terminal_instances[term_type]
  if not registry then
    return
  end

  local instance = registry.instances[index + 1]  -- Lua is 1-indexed
  if not instance then
    return
  end

  local win, _ = find_term_window(instance.id)
  if not win then
    return
  end

  -- Close and reopen to bring to front (z-order workaround)
  vim.api.nvim_win_close(win, false)

  vim.defer_fn(function()
    local offset = calculate_instance_offset(term_type, instance.offset_index)
    local cfg = get_default_config(term_type)
    local term = require("nvchad.term")

    term.toggle {
      pos = "float",
      id = instance.id,
      float_opts = {
        row = offset.row,
        col = offset.col,
        width = cfg.width,
        height = cfg.height,
        title = cfg.title .. " (" .. (index + 1) .. ")",  -- Show instance number
        title_pos = "center",
      }
    }

    -- Focus the reopened window
    local new_win, _ = find_term_window(instance.id)
    if new_win then
      vim.api.nvim_set_current_win(new_win)
      vim.cmd("startinsert")
    end
  end, 50)
end

-- Cycle focus between instances of the currently active terminal type
-- direction: "next" (clockwise) or "prev" (counter-clockwise)
local function cycle_instance(direction)
  if not _G.active_terminal_type then
    vim.notify("No terminal type is currently active", vim.log.levels.WARN)
    return
  end

  local term_type = _G.active_terminal_type
  local registry = _G.terminal_instances[term_type]

  if not registry or #registry.instances <= 1 then
    -- Nothing to cycle through (0 or 1 instance)
    return
  end

  local current_index = registry.focused_index
  local num_instances = #registry.instances

  -- Calculate next index with wrap-around
  local next_index
  if direction == "next" then
    next_index = (current_index + 1) % num_instances
  else  -- "prev"
    next_index = (current_index - 1) % num_instances
    -- Handle negative wrap-around
    if next_index < 0 then
      next_index = num_instances - 1
    end
  end

  -- Update focus
  registry.focused_index = next_index
  focus_instance(term_type, next_index)
end

wk.add {
  {
    "<leader>e",
    ":NvimTreeFindFile<CR>",
    desc = "focus file",
  },
  {
    "<leader>ra",
    function()
      require "nvchad.lsp.renamer"()
    end,
    desc = "rename",
    icon = {
      icon = "",
      color = "yellow",
    },
  },
  {
    "<leader>D",
    vim.lsp.buf.type_definition,
    desc = "go to type definition",
    icon = {
      icon = "󰅩",
      color = "azure",
    },
  },
  {
    "gD",
    vim.lsp.buf.declaration,
    desc = "go to declaration",
    icon = {
      icon = "󰅩",
      color = "blue",
    },
  },
  {
    "gd",
    vim.lsp.buf.definition,
    desc = "go to definition",
    icon = {
      icon = "󰅩",
      color = "cyan",
    },
  },
  {
    "gi",
    vim.lsp.buf.implementation,
    desc = "go to implementation",
    icon = {
      icon = "󰆧",
      color = "cyan",
    },
  },
  {
    "<leader>S",
    ":GrugFar<CR>",
    desc = "search and replace",
    icon = {
      icon = "",
      color = "yellow",
    },
  },
  {
    "gC",
    ":tabnew<CR>",
    desc = "new tab",
    icon = {
      icon = "",
      color = "green",
    },
  },
  {
    "gt",
    ":tabnext<CR>",
    desc = "next tab",
    icon = {
      icon = "",
      color = "yellow",
    },
  },
  {
    "gT",
    ":tabprevious<CR>",
    desc = "previous tab",
    icon = {
      icon = "",
      color = "yellow",
    },
  },
  {
    "gX",
    ":tabclose<CR>",
    desc = "close tab",
    icon = {
      icon = "󰅖",
      color = "red",
    },
  },
  {
    "<leader>X",
    ":BufOnly<CR>",
    desc = "close all other buffers",
    icon = "󰟢",
  },
  {
    "<leader>cd",
    function()
      local actions = require "telescope.actions"
      local action_state = require "telescope.actions.state"
      require("telescope.builtin").find_files {
        prompt_title = " Change Working Directory",
        cwd = vim.fn.expand "~",
        find_command = {
          "fd",
          "--type", "d",
          "--hidden",
          "--max-depth", "5",
          "--exclude", ".git",
          "--exclude", "node_modules",
          "--exclude", ".next",
          "--exclude", "dist",
          "--exclude", "build",
          "--exclude", "out",
          "--exclude", "target",
          "--exclude", ".cache",
          "--exclude", ".npm",
          "--exclude", ".yarn",
          "--exclude", "Library",
          "--exclude", ".Trash",
          "--exclude", ".cargo",
          "--exclude", ".rustup",
          "--exclude", "venv",
          "--exclude", ".venv",
          "--exclude", "env",
          "--exclude", ".terraform",
          "--exclude", "*.app",
        },
        previewer = false,
        layout_strategy = "center",
        layout_config = {
          height = 0.4,
          width = 0.5,
          preview_cutoff = 1,
        },
        sorting_strategy = "ascending",
        attach_mappings = function(prompt_bufnr, map)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if selection then
              local dir = selection.path or selection[1]
              vim.cmd("cd " .. vim.fn.fnameescape(dir))
              print(" Changed to: " .. dir)
            end
          end)
          return true
        end,
      }
    end,
    desc = "change directory (fuzzy)",
    icon = {
      icon = "",
      color = "azure",
    },
  },
  {
    mode = { "n", "v" }, -- NORMAL and VISUAL mode
    {
      "ga",
      vim.lsp.buf.code_action,
      desc = "code actions (LSP)",
      icon = {
        icon = "",
        color = "orange",
      },
      -- azure, blue, cyan, green, grey, orange, purple, red, yellow
    },
  },
  {
    "gpd",
    function()
      require("goto-preview").goto_preview_definition()
    end,
    desc = "preview definition",
    icon = {
      icon = "󰅩",
      color = "green",
    },
  },
  {
    "gpt",
    function()
      require("goto-preview").goto_preview_type_definition()
    end,
    desc = "preview type definition",
    icon = {
      icon = "󰊄",
      color = "green",
    },
  },
  {
    "gpi",
    function()
      require("goto-preview").goto_preview_implementation()
    end,
    desc = "preview implementation",
    icon = {
      icon = "󰆧",
      color = "green",
    },
  },
  {
    "gpD",
    function()
      require("goto-preview").goto_preview_declaration()
    end,
    desc = "preview declaration",
    icon = {
      icon = "󰀫",
      color = "green",
    },
  },
  {
    "gpr",
    function()
      require("goto-preview").goto_preview_references()
    end,
    desc = "preview references",
    icon = {
      icon = "󰈇",
      color = "green",
    },
  },
  {
    "gr",
    function()
      require("telescope.builtin").lsp_references()
    end,
    desc = "view references",
    icon = {
      icon = "󰈇",
      color = "green",
    },
  },
  {
    "gP",
    function()
      require("goto-preview").close_all_win()
    end,
    desc = "close preview",
    icon = "󰟢",
  },
  {
    mode = { "n", "v" }, -- NORMAL and VISUAL mode
    { "<leader>Q", "<cmd>qa<CR>", desc = "quit all", icon = "󰟢" },
    { "<leader>q", "<cmd>q<CR>", desc = "quit", icon = "󰟢" },
    { "<leader>w", "<cmd>w<CR>", desc = "write", icon = { icon = "", color = "green" } },
  },
  {
    "<leader>.",
    "@:",
    desc = "repeat last command",
    icon = {
      icon = "󰑖",
      color = "cyan",
    },
  },
  {
    "<leader><",
    function()
      require("smart-splits").resize_left(10)
    end,
    desc = "decrease width (repeatable)",
    icon = {
      icon = "󰼁",
      color = "blue",
    },
  },
  {
    "<leader>>",
    function()
      require("smart-splits").resize_right(10)
    end,
    desc = "increase width (repeatable)",
    icon = {
      icon = "󰼀",
      color = "blue",
    },
  },
  {
    "<leader>-",
    function()
      require("smart-splits").resize_down(5)
    end,
    desc = "decrease height (repeatable)",
    icon = {
      icon = "󰼃",
      color = "blue",
    },
  },
  {
    "<leader>+",
    function()
      require("smart-splits").resize_up(5)
    end,
    desc = "increase height (repeatable)",
    icon = {
      icon = "󰼂",
      color = "blue",
    },
  },
  {
    "<leader>tw",
    function()
      vim.wo.wrap = not vim.wo.wrap
    end,
    desc = "toggle word wrap",
    icon = {
      icon = "󰖶",
      color = "purple",
    },
  },
  {
    "<leader>mp",
    ":MarkdownPreviewToggle<CR>",
    desc = "toggle markdown preview",
    icon = {
      icon = "",
      color = "blue",
    },
  },
}

-- ============================================================================
-- Fuzzy Command Search Mappings (Alt+X and variants)
-- ============================================================================

-- Alt+Q: Fuzzy search all executables (floating terminal)
map({ "n", "t" }, "<A-q>", function()
  local term = require "nvchad.term"

  term.toggle {
    pos = "float",
    id = "fzf_all_commands",
    float_opts = {
      row = 0.05,
      col = 0.05,
      width = 0.9,
      height = 0.9,
      title = " 🔍 Command Search ",
      title_pos = "center",
    }
  }

  -- Auto-start the search on first open
  if not _G.fzf_all_started then
    local bufnr = vim.api.nvim_get_current_buf()  -- Capture buffer immediately
    vim.defer_fn(function()
      -- Use the captured buffer to avoid race conditions
      if bufnr and vim.bo[bufnr].buftype == "terminal" then
        local chan = vim.b[bufnr].terminal_job_id
        if chan then
          vim.api.nvim_chan_send(chan, "fzf-command-widget\n")
          _G.fzf_all_started = true
        end
      end
    end, 200)
  end
end, { desc = "fuzzy search all commands" })

-- Alt+Shift+G: Git commands (floating terminal)
map({ "n", "t" }, "<A-G>", function()
  local term = require "nvchad.term"

  term.toggle {
    pos = "float",
    id = "fzf_git_commands",
    float_opts = {
      row = 0.06,
      col = 0.06,
      width = 0.9,
      height = 0.9,
      title = " 🔍 Git Commands ",
      title_pos = "center",
    }
  }

  if not _G.fzf_git_started then
    local bufnr = vim.api.nvim_get_current_buf()  -- Capture buffer immediately
    vim.defer_fn(function()
      -- Use the captured buffer to avoid race conditions
      if bufnr and vim.bo[bufnr].buftype == "terminal" then
        local chan = vim.b[bufnr].terminal_job_id
        if chan then
          vim.api.nvim_chan_send(chan, "fzf-git-command-widget\n")
          _G.fzf_git_started = true
        end
      end
    end, 200)
  end
end, { desc = "fuzzy search git commands" })

-- Alt+Shift+D: Docker/K8s commands (floating terminal)
map({ "n", "t" }, "<A-D>", function()
  local term = require "nvchad.term"

  term.toggle {
    pos = "float",
    id = "fzf_docker_commands",
    float_opts = {
      row = 0.07,
      col = 0.07,
      width = 0.9,
      height = 0.9,
      title = " 🐳 Docker/K8s Commands ",
      title_pos = "center",
    }
  }

  if not _G.fzf_docker_started then
    local bufnr = vim.api.nvim_get_current_buf()  -- Capture buffer immediately
    vim.defer_fn(function()
      -- Use the captured buffer to avoid race conditions
      if bufnr and vim.bo[bufnr].buftype == "terminal" then
        local chan = vim.b[bufnr].terminal_job_id
        if chan then
          vim.api.nvim_chan_send(chan, "fzf-docker-command-widget\n")
          _G.fzf_docker_started = true
        end
      end
    end, 200)
  end
end, { desc = "fuzzy search docker/k8s commands" })

-- Alt+Shift+A: AWS commands (floating terminal)
map({ "n", "t" }, "<A-A>", function()
  local term = require "nvchad.term"

  term.toggle {
    pos = "float",
    id = "fzf_aws_commands",
    float_opts = {
      row = 0.08,
      col = 0.08,
      width = 0.9,
      height = 0.9,
      title = " ☁️  AWS Commands ",
      title_pos = "center",
    }
  }

  if not _G.fzf_aws_started then
    local bufnr = vim.api.nvim_get_current_buf()  -- Capture buffer immediately
    vim.defer_fn(function()
      -- Use the captured buffer to avoid race conditions
      if bufnr and vim.bo[bufnr].buftype == "terminal" then
        local chan = vim.b[bufnr].terminal_job_id
        if chan then
          vim.api.nvim_chan_send(chan, "fzf-aws-command-widget\n")
          _G.fzf_aws_started = true
        end
      end
    end, 200)
  end
end, { desc = "fuzzy search aws commands" })

-- Alt+Shift+X: Aliases and functions (floating terminal)
map({ "n", "t" }, "<A-X>", function()
  local term = require "nvchad.term"

  term.toggle {
    pos = "float",
    id = "fzf_aliases",
    float_opts = {
      row = 0.09,
      col = 0.09,
      width = 0.9,
      height = 0.9,
      title = " 🔧 Aliases & Functions ",
      title_pos = "center",
    }
  }

  if not _G.fzf_alias_started then
    local bufnr = vim.api.nvim_get_current_buf()  -- Capture buffer immediately
    vim.defer_fn(function()
      -- Use the captured buffer to avoid race conditions
      if bufnr and vim.bo[bufnr].buftype == "terminal" then
        local chan = vim.b[bufnr].terminal_job_id
        if chan then
          vim.api.nvim_chan_send(chan, "fzf-alias-widget\n")
          _G.fzf_alias_started = true
        end
      end
    end, 200)
  end
end, { desc = "fuzzy search aliases and functions" })

-- Alt+Shift+B: Homebrew packages (floating terminal)
map({ "n", "t" }, "<A-B>", function()
  local term = require "nvchad.term"

  term.toggle {
    pos = "float",
    id = "fzf_brew",
    float_opts = {
      row = 0.10,
      col = 0.10,
      width = 0.9,
      height = 0.9,
      title = " 🍺 Homebrew Packages ",
      title_pos = "center",
    }
  }

  if not _G.fzf_brew_started then
    local bufnr = vim.api.nvim_get_current_buf()  -- Capture buffer immediately
    vim.defer_fn(function()
      -- Use the captured buffer to avoid race conditions
      if bufnr and vim.bo[bufnr].buftype == "terminal" then
        local chan = vim.b[bufnr].terminal_job_id
        if chan then
          vim.api.nvim_chan_send(chan, "fzf-brew-widget\n")
          _G.fzf_brew_started = true
        end
      end
    end, 200)
  end
end, { desc = "fuzzy search homebrew packages" })

-- Track if we've started Claude in the terminal
_G.claude_started = false
_G.tmux_started = false

-- ALT+a toggles ALL Claude terminal instances (group toggle)
map({ "n", "t" }, "<A-a>", function()
  toggle_terminal_group("claude_term")
end, { desc = "toggle Claude Code terminal(s)" })

-- Note: Claude session prompt is handled in spawn_new_instance via auto_start_instance

-- ALT+s toggles ALL tmux terminal instances (group toggle)
-- Note: tmux auto-start handled in spawn_new_instance via auto_start_instance
map({ "n", "t" }, "<A-s>", function()
  toggle_terminal_group("tmux_term")
end, { desc = "toggle tmux terminal(s)" })

-- ALT+g toggles ALL k9s terminal instances (group toggle)
-- Note: k9s cluster selection handled in spawn_new_instance via auto_start_instance
map({ "n", "t" }, "<A-g>", function()
  toggle_terminal_group("k9s_term")
end, { desc = "toggle k9s terminal(s)" })

-- ALT+f toggles ALL lazygit terminal instances (group toggle)
map({ "n", "t" }, "<A-f>", function()
  toggle_terminal_group("lazygit_term")
end, { desc = "toggle lazygit terminal(s)" })

-- ALT+x toggles ALL OpenAI CLI terminal instances (group toggle)
map({ "n", "t" }, "<A-x>", function()
  toggle_terminal_group("openai_term")
end, { desc = "toggle OpenAI CLI terminal(s)" })

-- ALT+d toggles ALL lazydocker terminal instances (group toggle)
map({ "n", "t" }, "<A-d>", function()
  toggle_terminal_group("lazydockerTerm")
end, { desc = "toggle lazydocker terminal(s)" })

-- ALT+e toggles ALL e1s terminal instances (group toggle)
-- Note: e1s profile/region selection handled in spawn_new_instance via auto_start_instance
map({ "n", "t" }, "<A-e>", function()
  toggle_terminal_group("e1sTerm")
end, { desc = "toggle e1s AWS ECS terminal(s)" })

-- ALT+r toggles ALL posting terminal instances (group toggle)
map({ "n", "t" }, "<A-r>", function()
  toggle_terminal_group("posting_term")
end, { desc = "toggle posting API client terminal(s)" })

-- ============================================================================
-- Spawn New Terminal Instances (<leader>n<key>)
-- ============================================================================
-- These keybindings create additional instances of terminal types
-- Note: Alt+Shift+<key> was originally planned but conflicts with command search

-- <leader>na: Spawn new Claude Code instance
map({ "n", "t" }, "<leader>na", function()
  spawn_new_instance("claude_term")
end, { desc = "spawn new Claude Code instance" })

-- <leader>ns: Spawn new tmux instance
map({ "n", "t" }, "<leader>ns", function()
  spawn_new_instance("tmux_term")
end, { desc = "spawn new tmux instance" })

-- <leader>ng: Spawn new k9s instance
map({ "n", "t" }, "<leader>ng", function()
  spawn_new_instance("k9s_term")
end, { desc = "spawn new k9s instance" })

-- <leader>nf: Spawn new lazygit instance
map({ "n", "t" }, "<leader>nf", function()
  spawn_new_instance("lazygit_term")
end, { desc = "spawn new lazygit instance" })

-- <leader>nx: Spawn new OpenAI Codex instance
map({ "n", "t" }, "<leader>nx", function()
  spawn_new_instance("openai_term")
end, { desc = "spawn new OpenAI Codex instance" })

-- <leader>nd: Spawn new lazydocker instance
map({ "n", "t" }, "<leader>nd", function()
  spawn_new_instance("lazydockerTerm")
end, { desc = "spawn new lazydocker instance" })

-- <leader>nr: Spawn new posting instance
map({ "n", "t" }, "<leader>nr", function()
  spawn_new_instance("posting_term")
end, { desc = "spawn new posting instance" })

-- <leader>ne: Spawn new e1s instance
map({ "n", "t" }, "<leader>ne", function()
  spawn_new_instance("e1sTerm")
end, { desc = "spawn new e1s instance" })

-- ============================================================================
-- Cycling Keybindings
-- ============================================================================

-- ALT+] cycles to next instance (clockwise)
map({ "n", "t" }, "<A-]>", function()
  cycle_instance("next")
end, { desc = "cycle to next terminal instance" })

-- ALT+[ cycles to previous instance (counter-clockwise)
map({ "n", "t" }, "<A-[>", function()
  cycle_instance("prev")
end, { desc = "cycle to previous terminal instance" })

-- ALT+z closes and kills any floating terminal
-- Note: When in terminal mode with apps like k9s running, press Ctrl+q first to exit terminal mode,
-- then press ALT+z. Or use this mapping which attempts to kill the process first.
map({ "n", "t" }, "<A-z>", function()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].buftype == "terminal" then
    local nvim_pid = vim.fn.getpid()

    -- Kill tmux session if this is the tracked tmux terminal buffer
    if _G.tmux_terminal_buffer and bufnr == _G.tmux_terminal_buffer then
      local session_name = "nvim_" .. nvim_pid
      vim.fn.system("tmux kill-session -t " .. session_name .. " 2>/dev/null")
      _G.tmux_terminal_buffer = nil -- Clear tracked buffer
    end

    -- Try to stop the terminal job for other processes (k9s, openai, etc)
    local success, job_id = pcall(vim.api.nvim_buf_get_var, bufnr, "terminal_job_id")
    if success and job_id then
      vim.fn.jobstop(job_id)
    end

    -- Reset all terminal session tracking
    _G.claude_started = false
    _G.k9s_started = false
    _G.openai_started = false
    _G.lazydocker_started = false
    _G.e1s_started = false
    _G.e2s_started = false
    _G.fzf_all_started = false
    _G.fzf_git_started = false
    _G.fzf_docker_started = false
    _G.fzf_aws_started = false
    _G.fzf_alias_started = false
    _G.fzf_brew_started = false

    -- Delete the buffer (force = true to handle unsaved changes)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end, { desc = "kill any floating terminal" })

-- ALT+Shift+? shows floating terminal shortcuts cheatsheet
map({ "n", "t" }, "<A-?>", function()
  -- Create buffer with shortcut information
  local buf = vim.api.nvim_create_buf(false, true)

  local shortcuts = {
    "╭─────────────────────────────────────────────────────╮",
    "│     Floating Terminal Shortcuts (Left-Hand)        │",
    "╰─────────────────────────────────────────────────────╯",
    "",
    "  Home Row (Most Used)",
    "  ────────────────────",
    "  ALT+a  →  Claude Code AI assistant",
    "  ALT+s  →  Tmux multiplexer terminal",
    "  ALT+d  →  Lazydocker (Docker TUI)",
    "  ALT+f  →  Lazygit (Git TUI)",
    "  ALT+g  →  k9s (Kubernetes browser)",
    "",
    "  Top Row (Secondary Tools)",
    "  ─────────────────────────",
    "  ALT+e  →  e1s (AWS ECS browser)",
    "  ALT+r  →  Posting (HTTP API client)",
    "",
    "  Bottom Row",
    "  ──────────",
    "  ALT+x  →  OpenAI Codex CLI",
    "  ALT+z  →  Kill/close current terminal",
    "",
    "  Command Search",
    "  ──────────────",
    "  ALT+q        →  Search all commands",
    "  ALT+Shift+G  →  Git commands",
    "  ALT+Shift+D  →  Docker/K8s commands",
    "  ALT+Shift+A  →  AWS commands",
    "  ALT+Shift+X  →  Aliases/functions",
    "  ALT+Shift+B  →  Homebrew packages",
    "",
    "  Press any key to close",
  }

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, shortcuts)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Calculate centered position
  local width = 57
  local height = #shortcuts
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Open floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Terminal Shortcuts ",
    title_pos = "center",
  })

  -- Close on any key press
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", "<cmd>close<CR>", { buffer = buf, nowait = true })

  -- Auto-close after any character key
  for _, key in ipairs({"a", "s", "d", "f", "g", "x", "e", "r", "z", "h", "j", "k", "l"}) do
    vim.keymap.set("n", key, "<cmd>close<CR>", { buffer = buf, nowait = true })
  end
end, { desc = "show terminal shortcuts cheatsheet" })

-- Avante.nvim AI assistant keybindings
-- Note: ALT+a is used by Claude terminal, use <leader>aa for avante
map({ "n", "v" }, "<leader>aa", function()
  require("avante.api").ask()
end, { desc = "avante: ask" })

map("n", "<leader>ar", function()
  require("avante.api").refresh()
end, { desc = "avante: refresh" })

map("v", "<leader>ae", function()
  require("avante.api").edit()
end, { desc = "avante: edit selection" })

map("n", "<leader>af", function()
  require("avante.api").focus()
end, { desc = "avante: focus sidebar" })

map("n", "<leader>at", function()
  require("avante").toggle()
end, { desc = "avante: toggle sidebar" })

-- macOS clipboard integration: CMD+v in visual mode
-- Pastes from clipboard and saves the replaced text back to clipboard
map("v", "<D-v>", function()
  -- Save what's currently in the clipboard (what we want to paste)
  local clipboard_content = vim.fn.getreg('+')
  -- Yank the visual selection to clipboard (temporarily)
  vim.cmd('normal! "+y')
  -- Save the selected text that we just yanked
  local selected_text = vim.fn.getreg('+')
  -- Restore the original clipboard content
  vim.fn.setreg('+', clipboard_content)
  -- Paste from clipboard (replaces the selection)
  vim.cmd('normal! gv"+p')
  -- Put the replaced text back into the clipboard
  vim.fn.setreg('+', selected_text)
end, { desc = "paste from clipboard, save replaced text to clipboard" })

-- macOS clipboard integration: Yank operations
-- Explicitly copy to system clipboard when yanking
-- Note: With clipboard=unnamedplus, these work automatically, but explicit mappings ensure clarity

-- Visual mode: yank to clipboard
map("v", "y", '"+y', { desc = "yank to clipboard" })

-- Normal mode: yank line to clipboard
map("n", "yy", '"+yy', { desc = "yank line to clipboard" })

-- Normal mode: yank motion to clipboard (e.g., yw, y$, yap)
map("n", "y", '"+y', { desc = "yank motion to clipboard" })

-- Visual mode: CMD+c to copy (macOS standard)
map("v", "<D-c>", '"+y', { desc = "copy to clipboard" })

-- Cleanup: Kill tmux session when Neovim exits
-- This prevents orphaned tmux sessions when closing wezterm tabs
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    local nvim_pid = vim.fn.getpid()
    local session_name = "nvim_" .. nvim_pid
    -- Kill tmux session silently (ignore errors if session doesn't exist)
    vim.fn.system("tmux kill-session -t " .. session_name .. " 2>/dev/null")
  end,
  desc = "Kill tmux session on Neovim exit"
})
