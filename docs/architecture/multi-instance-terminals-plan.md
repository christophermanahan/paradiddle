# Multi-Instance Floating Terminals Implementation Plan

**Status:** Planning
**Created:** 2025-01-05
**Branch:** `feature/multi-instance-terminals`
**Related:** [floating-terminal-focus.md](../implementation/floating-terminal-focus.md)

---

## Executive Summary

This plan extends Paradiddle's floating terminal system to support **multiple instances** of each terminal type (Claude Code, tmux, k9s, etc.), with intelligent cycling, stacking, and focus management.

### Key Features

1. **Multi-Instance Spawning**: `Alt+Shift+<key>` spawns additional instances of any terminal type
2. **Diagonal Stacking**: New instances offset 5-10 pixels diagonally for visual distinction
3. **Type-Scoped Cycling**: `Alt+[` and `Alt+]` cycle through instances of the **currently active** terminal type only
4. **Group Toggle**: `Alt+<key>` shows/hides **all instances** of that terminal type
5. **Instance-Aware Close**: `Alt+z` closes only the **currently focused instance**
6. **Session Continuity**: Each Claude instance gets the session prompt independently

---

## Current System Analysis

### Existing Architecture

**File:** `nvim/.config/nvim/lua/mappings.lua`

#### Global State Tracking
```lua
_G.foreground_terminal = nil           -- Currently visible terminal type (e.g., "claude_term")
_G.terminal_buffers = {}               -- Set of created terminal buffers
_G.claude_started = false              -- Has Claude auto-started?
_G.tmux_started = false                -- Has tmux auto-started?
_G.tmux_terminal_buffer = nil          -- Tracked tmux buffer number
```

#### Key Functions
1. **`find_term_window(term_id)`** (line ~125): Finds window for a given term_id
2. **`find_term_buffer(term_id)`** (line ~135): Finds buffer for a given term_id
3. **`prepare_toggle(term_id)`** (line ~149): Smart toggle with foreground tracking

#### Terminal Lifecycle
1. **Open**: `term.toggle { id = term_id, ... }` creates/shows terminal
2. **Auto-start**: `vim.defer_fn()` with 200ms delay sends initial commands
3. **Toggle**: Reusing same term_id shows/hides the single instance
4. **Close**: `Alt+z` kills job and closes buffer

### Limitations of Current System
- ❌ Only one instance per terminal type (e.g., one Claude terminal)
- ❌ No way to spawn additional instances
- ❌ No cycling mechanism for multiple instances
- ❌ Closing a terminal resets the started flag globally

---

## Proposed Architecture

### Data Structure Changes

#### 1. Instance Tracking Registry

Replace single `_G.foreground_terminal` with structured registry:

```lua
_G.terminal_instances = {
  claude_term = {
    active_type = "claude_term",          -- Currently active terminal type
    instances = {                         -- List of instances for this type
      { id = "claude_term_1", bufnr = 10, started = true,  offset_index = 0 },
      { id = "claude_term_2", bufnr = 15, started = true,  offset_index = 1 },
      { id = "claude_term_3", bufnr = 20, started = false, offset_index = 2 },
    },
    focused_index = 2,                    -- Currently focused instance (0-indexed)
    visible = true,                       -- Are instances of this type visible?
  },
  tmux_term = {
    active_type = "tmux_term",
    instances = {
      { id = "tmux_term_1", bufnr = 12, started = true, offset_index = 0 },
      { id = "tmux_term_2", bufnr = 18, started = true, offset_index = 1 },
    },
    focused_index = 0,
    visible = false,
  },
  -- ... other terminal types
}

-- Track which terminal TYPE is currently in foreground (replaces _G.foreground_terminal)
_G.active_terminal_type = nil  -- e.g., "claude_term" or "tmux_term"
```

#### 2. Offset Calculation

```lua
-- Base offsets for each terminal type (existing values)
local BASE_OFFSETS = {
  claude_term  = { row = 0.02, col = 0.02 },
  tmux_term    = { row = 0.03, col = 0.03 },
  k9s_term     = { row = 0.04, col = 0.04 },
  lazygit_term = { row = 0.05, col = 0.05 },
  openai_term  = { row = 0.06, col = 0.06 },
  lazydocker_term = { row = 0.07, col = 0.07 },
  posting_term = { row = 0.08, col = 0.08 },
  e1s_term     = { row = 0.09, col = 0.09 },
}

-- Calculate diagonal offset for instance N
local function calculate_instance_offset(term_type, instance_index)
  local base = BASE_OFFSETS[term_type]
  local pixel_offset = 0.007 * instance_index  -- ~7 pixels diagonal per instance

  return {
    row = base.row + pixel_offset,
    col = base.col + pixel_offset,
  }
end
```

**Visual Example:**
```
┌─────────────────────────────────┐
│                                 │
│  ┌────────────────┐             │
│  │ Claude 1       │             │
│  │  ┌────────────────┐          │
│  │  │ Claude 2       │          │
│  │  │  ┌────────────────┐       │
│  │  │  │ Claude 3 (focus)│      │
│  │  │  │                 │      │
│  └──│──│─────────────────┘      │
│     └──│────────────────────────┘
│        └────────────────────────┘
```

---

## Keybinding Changes

### New Keybindings

| Key | Current Behavior | New Behavior |
|-----|------------------|--------------|
| `Alt+a` | Toggle single Claude terminal | Toggle ALL Claude instances (show/hide group) |
| `Alt+Shift+A` | *(not bound)* | **NEW**: Spawn new Claude instance |
| `Alt+s` | Toggle single tmux terminal | Toggle ALL tmux instances |
| `Alt+Shift+S` | *(not bound)* | **NEW**: Spawn new tmux instance |
| *(same for all terminal types)* |
| `Alt+[` | *(not bound)* | **NEW**: Cycle to previous instance (counter-clockwise) |
| `Alt+]` | *(not bound)* | **NEW**: Cycle to next instance (clockwise) |
| `Alt+z` | Close current terminal | Close **only** focused instance of active type |

### Spawn Pattern (Alt+Shift+<key>)

```lua
-- Example: Alt+Shift+A spawns new Claude instance
map({ "n", "t" }, "<A-S-a>", function()
  spawn_new_instance("claude_term", {
    command = "claude",  -- or session prompt script
    title = "Claude Code 🤖",
    width = 0.85,
    height = 0.85,
  })
end, { desc = "spawn new Claude Code instance" })
```

### Cycling Pattern (Alt+[ and Alt+])

```lua
-- Cycle to next instance (clockwise)
map({ "n", "t" }, "<A-]>", function()
  cycle_instance("next")
end, { desc = "cycle to next terminal instance" })

-- Cycle to previous instance (counter-clockwise)
map({ "n", "t" }, "<A-[>", function()
  cycle_instance("prev")
end, { desc = "cycle to previous terminal instance" })
```

---

## Core Functions

### 1. `spawn_new_instance(term_type, config)`

**Purpose:** Create a new instance of a terminal type

**Algorithm:**
```lua
function spawn_new_instance(term_type, config)
  -- 1. Get or create instance registry for this type
  if not _G.terminal_instances[term_type] then
    _G.terminal_instances[term_type] = {
      instances = {},
      focused_index = 0,
      visible = false,
    }
  end

  local registry = _G.terminal_instances[term_type]

  -- 2. Calculate next instance ID and offset
  local next_index = #registry.instances
  local instance_id = term_type .. "_" .. (next_index + 1)
  local offset = calculate_instance_offset(term_type, next_index)

  -- 3. Create terminal with NvChad
  local term = require("nvchad.term")
  term.toggle {
    pos = "float",
    id = instance_id,
    float_opts = {
      row = offset.row,
      col = offset.col,
      width = config.width,
      height = config.height,
      title = config.title,
      title_pos = "center",
    }
  }

  -- 4. Register instance
  local bufnr = vim.api.nvim_get_current_buf()
  table.insert(registry.instances, {
    id = instance_id,
    bufnr = bufnr,
    started = false,
    offset_index = next_index,
  })

  -- 5. Update focus
  registry.focused_index = next_index
  registry.visible = true
  _G.active_terminal_type = term_type

  -- 6. Auto-start if config provides command
  if config.command then
    auto_start_instance(instance_id, config.command, bufnr)
  end
end
```

### 2. `toggle_terminal_group(term_type)`

**Purpose:** Show/hide ALL instances of a terminal type

**Algorithm:**
```lua
function toggle_terminal_group(term_type)
  local registry = _G.terminal_instances[term_type]
  if not registry or #registry.instances == 0 then
    -- No instances exist, spawn first one
    spawn_new_instance(term_type, get_default_config(term_type))
    return
  end

  local currently_visible = registry.visible

  if currently_visible then
    -- HIDE: Close all windows for this type
    for _, instance in ipairs(registry.instances) do
      local win = find_term_window(instance.id)
      if win then
        vim.api.nvim_win_close(win, false)
      end
    end
    registry.visible = false
    _G.active_terminal_type = nil
  else
    -- SHOW: Open all instances with their offsets
    -- First, hide any OTHER terminal type that's currently visible
    if _G.active_terminal_type and _G.active_terminal_type ~= term_type then
      toggle_terminal_group(_G.active_terminal_type)  -- Hide other type
    end

    -- Show all instances of this type
    for i, instance in ipairs(registry.instances) do
      local offset = calculate_instance_offset(term_type, instance.offset_index)
      local term = require("nvchad.term")
      term.toggle {
        pos = "float",
        id = instance.id,
        float_opts = {
          row = offset.row,
          col = offset.col,
          width = 0.85,
          height = 0.85,
          title = get_title_for_type(term_type),
          title_pos = "center",
        }
      }
    end

    registry.visible = true
    _G.active_terminal_type = term_type

    -- Focus the last focused instance
    focus_instance(term_type, registry.focused_index)
  end
end
```

### 3. `cycle_instance(direction)`

**Purpose:** Cycle focus between instances of the currently active terminal type

**Algorithm:**
```lua
function cycle_instance(direction)
  if not _G.active_terminal_type then
    vim.notify("No terminal type is currently active", vim.log.levels.WARN)
    return
  end

  local term_type = _G.active_terminal_type
  local registry = _G.terminal_instances[term_type]

  if not registry or #registry.instances <= 1 then
    -- Nothing to cycle through
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
  end

  -- Update focus
  registry.focused_index = next_index
  focus_instance(term_type, next_index)
end
```

### 4. `focus_instance(term_type, index)`

**Purpose:** Bring a specific instance to the front

**Algorithm:**
```lua
function focus_instance(term_type, index)
  local registry = _G.terminal_instances[term_type]
  local instance = registry.instances[index + 1]  -- Lua is 1-indexed

  if not instance then
    return
  end

  local win = find_term_window(instance.id)
  if win then
    -- Bring window to front by closing and reopening
    -- (NvChad doesn't have native z-order control)
    vim.api.nvim_win_close(win, false)

    vim.defer_fn(function()
      local offset = calculate_instance_offset(term_type, instance.offset_index)
      local term = require("nvchad.term")
      term.toggle {
        pos = "float",
        id = instance.id,
        float_opts = {
          row = offset.row,
          col = offset.col,
          width = 0.85,
          height = 0.85,
          title = get_title_for_type(term_type),
          title_pos = "center",
        }
      }

      -- Focus the reopened window
      local new_win = find_term_window(instance.id)
      if new_win then
        vim.api.nvim_set_current_win(new_win)
        vim.cmd("startinsert")
      end
    end, 50)
  end
end
```

### 5. `close_focused_instance()`

**Purpose:** Close only the currently focused instance

**Algorithm:**
```lua
function close_focused_instance()
  if not _G.active_terminal_type then
    -- Fallback to old behavior if no multi-instance terminal is active
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype == "terminal" then
      vim.cmd("close")
    end
    return
  end

  local term_type = _G.active_terminal_type
  local registry = _G.terminal_instances[term_type]
  local focused_idx = registry.focused_index
  local instance = registry.instances[focused_idx + 1]  -- Lua 1-indexed

  if not instance then
    return
  end

  -- 1. Kill the terminal job
  local success, job_id = pcall(vim.api.nvim_buf_get_var, instance.bufnr, "terminal_job_id")
  if success and job_id then
    vim.fn.jobstop(job_id)
  end

  -- 2. Close the window
  local win = find_term_window(instance.id)
  if win then
    vim.api.nvim_win_close(win, false)
  end

  -- 3. Remove instance from registry
  table.remove(registry.instances, focused_idx + 1)

  -- 4. Update focus
  if #registry.instances == 0 then
    -- No instances left, clear registry
    _G.terminal_instances[term_type] = nil
    _G.active_terminal_type = nil
  else
    -- Focus previous instance (with wrap-around)
    registry.focused_index = math.max(0, focused_idx - 1)
    focus_instance(term_type, registry.focused_index)
  end
end
```

---

## Implementation Phases

### Phase 1: Data Structure Refactoring (2-3 hours)
**Goal:** Implement instance registry without changing behavior

**Tasks:**
1. Create `_G.terminal_instances` registry structure
2. Migrate existing single-instance logic to use registry
3. Update `prepare_toggle()` to work with registry
4. Test that all existing terminals still work identically

**Validation:** All 8 terminals toggle normally, no regressions

---

### Phase 2: Spawn Functionality (2-3 hours)
**Goal:** Add ability to spawn new instances

**Tasks:**
1. Implement `spawn_new_instance()` function
2. Implement `calculate_instance_offset()` function
3. Add `Alt+Shift+<key>` keybindings for all 8 terminal types
4. Update auto-start logic to be instance-aware

**Validation:** Can spawn 3 Claude instances with diagonal offsets

---

### Phase 3: Group Toggle (1-2 hours)
**Goal:** Toggle all instances of a type together

**Tasks:**
1. Implement `toggle_terminal_group()` function
2. Update existing `Alt+<key>` mappings to use group toggle
3. Test showing/hiding multiple instances

**Validation:** `Alt+a` shows/hides all Claude instances, `Alt+s` shows/hides all tmux instances

---

### Phase 4: Cycling Mechanism (2-3 hours)
**Goal:** Navigate between instances with Alt+[ and Alt+]

**Tasks:**
1. Implement `cycle_instance()` function
2. Implement `focus_instance()` function
3. Add `Alt+[` and `Alt+]` keybindings
4. Handle z-order by close/reopen trick

**Validation:** Can cycle through 3 Claude instances in both directions

---

### Phase 5: Instance-Aware Close (1 hour)
**Goal:** Close only focused instance

**Tasks:**
1. Implement `close_focused_instance()` function
2. Update `Alt+z` mapping to use new function
3. Handle focus shifting when closing

**Validation:** Can close individual instances, focus shifts correctly

---

### Phase 6: Polish & Testing (2-3 hours)
**Goal:** Edge cases and UX refinements

**Tasks:**
1. Update shortcuts cheatsheet (`Alt+Shift+?`)
2. Add visual indicators for instance count
3. Test all edge cases (see below)
4. Update documentation

**Validation:** All scenarios work smoothly

---

## Edge Cases & Considerations

### Edge Cases to Test

1. **Spawn with no instances**: First `Alt+Shift+A` should create instance 1
2. **Spawn at max instances**: Decide limit (e.g., 5 per type?) or unlimited
3. **Close last instance**: Should clear registry and reset `active_terminal_type`
4. **Close middle instance**: Should shift indices correctly
5. **Toggle with mixed visibility**: Some instances visible, some not (shouldn't happen with group toggle)
6. **Cycle with 1 instance**: Should be no-op
7. **Cycle with terminal type not active**: Should show warning
8. **Switch terminal types mid-cycle**: `Alt+s` should hide Claude group, show tmux group
9. **Auto-start on each instance**: Each Claude instance should get session prompt independently
10. **Buffer cleanup**: Deleted buffers should be removed from registry

### Technical Constraints

1. **Z-order limitation**: NvChad floating windows don't support native z-order
   - **Solution**: Close/reopen trick to bring window to front
   - **Trade-off**: Slight flicker (~50ms) when cycling

2. **Offset precision**: Row/col are percentage-based (0.0-1.0)
   - **Solution**: Use ~0.007 per instance (~7 pixels on 1920x1080)
   - **Limitation**: May not work perfectly on very small terminals

3. **Instance limit**: Too many instances will overlap completely
   - **Recommendation**: Soft limit of 5 instances per type
   - **Hard limit**: 10 instances (after which offsets wrap?)

4. **Memory usage**: Each instance is a full terminal buffer
   - **Acceptable**: Modern systems can handle 20-30 terminal buffers easily

### UX Considerations

1. **Visual feedback for cycling**: Flash border or show instance number?
   - **Proposal**: Update title to "Claude Code 🤖 (2/3)" during cycle

2. **Keyboard muscle memory**: `Alt+a` behavior changes from "toggle single" to "toggle group"
   - **Migration**: Should feel natural since it's still "show/hide Claude terminals"

3. **Discoverability**: How do users learn about `Alt+Shift+A`?
   - **Solution**: Update cheatsheet and add to docs

4. **Instance naming**: Should instances have unique names? (e.g., "Claude Code A", "Claude Code B")
   - **Proposal**: Keep same title, differentiate in cheatsheet or with instance count

---

## Testing Plan

### Manual Test Scenarios

#### Scenario 1: Basic Multi-Instance Workflow
```
1. Press Alt+a → Claude 1 opens
2. Press Alt+Shift+A → Claude 2 opens (offset diagonally)
3. Press Alt+Shift+A → Claude 3 opens (offset further)
4. Press Alt+] → Focus cycles: 3 → 1 → 2 → 3 (clockwise)
5. Press Alt+[ → Focus cycles: 3 → 2 → 1 → 3 (counter-clockwise)
6. Press Alt+z → Claude 3 closes (focused)
7. Press Alt+] → Focus cycles: 2 → 1 → 2
8. Press Alt+a → All Claude instances hide
9. Press Alt+a → All Claude instances show again
10. Press Alt+z twice → All instances close
```

#### Scenario 2: Type Switching
```
1. Press Alt+a → Claude 1 opens
2. Press Alt+Shift+A → Claude 2 opens
3. Press Alt+s → Claude group hides, Tmux 1 opens
4. Press Alt+Shift+S → Tmux 2 opens
5. Press Alt+] → Cycles through Tmux 1 → 2 (not Claude)
6. Press Alt+a → Tmux group hides, Claude group shows
7. Press Alt+] → Cycles through Claude 1 → 2 (not Tmux)
```

#### Scenario 3: Close Behavior
```
1. Spawn 3 Claude instances
2. Focus Claude 2 (using Alt+])
3. Press Alt+z → Only Claude 2 closes
4. Focus shifts to Claude 1
5. Press Alt+a → Hides remaining instances
6. Press Alt+a → Shows remaining instances (1 and 3)
```

#### Scenario 4: Session Continuity (Claude-specific)
```
1. Press Alt+a → Claude 1 opens with session prompt
2. Choose "Continue" → Claude 1 continues previous session
3. Press Alt+Shift+A → Claude 2 opens with session prompt
4. Choose "Fresh" → Claude 2 starts fresh
5. Both instances should be independent
```

### Automated Tests (Future)

```lua
-- Example: Test spawn and cycle
describe("Multi-instance terminals", function()
  it("should spawn multiple instances with offsets", function()
    spawn_new_instance("claude_term", default_config)
    spawn_new_instance("claude_term", default_config)

    local registry = _G.terminal_instances["claude_term"]
    assert.equal(#registry.instances, 2)
    assert.not_equal(registry.instances[1].offset_index, registry.instances[2].offset_index)
  end)

  it("should cycle focus correctly", function()
    -- Setup 3 instances
    local registry = setup_three_instances("claude_term")

    registry.focused_index = 0
    cycle_instance("next")
    assert.equal(registry.focused_index, 1)

    cycle_instance("next")
    assert.equal(registry.focused_index, 2)

    cycle_instance("next")  -- Wrap around
    assert.equal(registry.focused_index, 0)
  end)
end)
```

---

## Documentation Updates

### Files to Update

1. **`CLAUDE.md`** - Add section on multi-instance usage
2. **`docs/README.md`** - Update terminal keybindings table
3. **`docs/implementation/floating-terminal-focus.md`** - Extend with multi-instance architecture
4. **Shortcuts cheatsheet** (in `mappings.lua`) - Add `Alt+Shift+<key>` and cycling keys

### Example Documentation Snippet

```markdown
## Multi-Instance Terminals

Paradiddle supports **multiple instances** of any terminal type:

### Spawning Instances
- `Alt+a` - Toggle Claude Code instance(s)
- `Alt+Shift+A` - Spawn NEW Claude Code instance

### Cycling Between Instances
- `Alt+]` - Focus next instance (clockwise)
- `Alt+[` - Focus previous instance (counter-clockwise)

### Managing Instances
- `Alt+z` - Close currently focused instance
- Closing last instance resets the terminal type

### Example Workflow
```
Alt+a         # Open Claude 1
Alt+Shift+A   # Spawn Claude 2 (offset diagonally)
Alt+Shift+A   # Spawn Claude 3
Alt+]         # Cycle focus: 3 → 1 → 2 → 3
Alt+z         # Close focused instance
Alt+a         # Hide all remaining Claude instances
```
```

---

## Success Criteria

### Functional Requirements
- ✅ Can spawn unlimited instances of any terminal type
- ✅ Instances have unique IDs and diagonal offsets
- ✅ `Alt+<key>` toggles all instances of that type
- ✅ `Alt+Shift+<key>` spawns new instance
- ✅ `Alt+]` cycles forward through instances
- ✅ `Alt+[` cycles backward through instances
- ✅ Cycling is scoped to active terminal type only
- ✅ `Alt+z` closes only focused instance
- ✅ Focus shifts correctly after close
- ✅ Each Claude instance gets independent session prompt

### Non-Functional Requirements
- ✅ No regressions to existing single-instance behavior
- ✅ Cycle latency < 100ms (close/reopen time)
- ✅ Offset calculation works on all common screen sizes
- ✅ Memory usage stays reasonable (< 500MB for 20 terminals)
- ✅ Code is maintainable with clear function separation

### User Experience
- ✅ Keybindings feel intuitive and consistent
- ✅ Visual distinction between instances (offset + optional title)
- ✅ Cheatsheet updated with new keybindings
- ✅ Documentation clearly explains multi-instance workflow

---

## Implementation Checklist

### Phase 1: Data Structure Refactoring
- [ ] Create `_G.terminal_instances` registry structure
- [ ] Implement `calculate_instance_offset(term_type, index)`
- [ ] Update `find_term_window()` and `find_term_buffer()` to work with instance IDs
- [ ] Migrate `prepare_toggle()` to use registry
- [ ] Test: All 8 terminals toggle normally

### Phase 2: Spawn Functionality
- [ ] Implement `spawn_new_instance(term_type, config)`
- [ ] Implement `auto_start_instance(instance_id, command, bufnr)`
- [ ] Add `Alt+Shift+A` (Claude spawn)
- [ ] Add `Alt+Shift+S` (tmux spawn)
- [ ] Add `Alt+Shift+G` (k9s spawn)
- [ ] Add `Alt+Shift+F` (lazygit spawn)
- [ ] Add `Alt+Shift+X` (OpenAI spawn)
- [ ] Add `Alt+Shift+D` (lazydocker spawn)
- [ ] Add `Alt+Shift+R` (posting spawn)
- [ ] Add `Alt+Shift+E` (e1s spawn)
- [ ] Test: Can spawn 3 instances with offsets

### Phase 3: Group Toggle
- [ ] Implement `toggle_terminal_group(term_type)`
- [ ] Update `Alt+a` to use group toggle
- [ ] Update `Alt+s` to use group toggle
- [ ] Update all 8 terminal toggles
- [ ] Test: Toggle shows/hides all instances

### Phase 4: Cycling Mechanism
- [ ] Implement `cycle_instance(direction)`
- [ ] Implement `focus_instance(term_type, index)`
- [ ] Add `Alt+]` keybinding
- [ ] Add `Alt+[` keybinding
- [ ] Test z-order management (close/reopen trick)
- [ ] Test: Cycle through 3 instances both directions

### Phase 5: Instance-Aware Close
- [ ] Implement `close_focused_instance()`
- [ ] Update `Alt+z` to use new function
- [ ] Handle focus shift after close
- [ ] Handle registry cleanup when last instance closes
- [ ] Test: Close individual instances, focus shifts correctly

### Phase 6: Polish & Testing
- [ ] Update shortcuts cheatsheet (`Alt+Shift+?`)
- [ ] Add instance count to terminal titles
- [ ] Test all edge cases (see list above)
- [ ] Update `CLAUDE.md` documentation
- [ ] Update `docs/README.md`
- [ ] Update `docs/implementation/floating-terminal-focus.md`
- [ ] Test complete workflows (scenarios 1-4)

---

## Questions & Decisions

### Open Questions
1. **Instance limit**: Hard limit per type? (Recommendation: 10)
2. **Instance naming**: Show instance number in title? (Recommendation: "Claude Code 🤖 (2/3)")
3. **Spawn position**: Always spawn at next offset, or spawn at cursor position?
4. **Persist instances**: Should instances survive nvim restart? (Recommendation: No, too complex)
5. **Visual indicator**: Show all instance borders when type is active? (Recommendation: No, too noisy)

### Decisions Made
1. **Z-order**: Use close/reopen trick (accepted trade-off)
2. **Offset calculation**: 0.007 per instance (~7px diagonal)
3. **Cycling scope**: Type-specific only (not global)
4. **Group toggle**: All instances show/hide together
5. **Auto-start**: Each instance gets auto-start independently

---

## Rollout Plan

### Development Branch
```bash
git checkout -b feature/multi-instance-terminals
git push -u origin feature/multi-instance-terminals
```

### Merge Strategy
1. Complete Phase 1-2, open draft PR for early feedback
2. Complete Phase 3-4, mark PR ready for review
3. Complete Phase 5-6, final testing
4. Merge to main after approval

### Rollback Plan
If serious issues arise:
1. Revert merge commit
2. Fix issues in feature branch
3. Re-merge with fixes

---

## Related Documents

- [floating-terminal-focus.md](../implementation/floating-terminal-focus.md) - Current terminal focus system
- [CLAUDE.md](../../CLAUDE.md) - User-facing keybinding documentation
- [mappings.lua](../../nvim/.config/nvim/lua/mappings.lua) - Implementation file

---

**Document Version:** 1.0
**Last Updated:** 2025-01-05
**Author:** Planning session with Claude Code
