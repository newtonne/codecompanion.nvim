local config = require("codecompanion.config")

local file_utils = require("codecompanion.utils.files")
local log = require("codecompanion.utils.log")
local tokens_utils = require("codecompanion.utils.tokens")
local util = require("codecompanion.utils.util")
local ts = vim.treesitter

CONSTANTS = {
  NAME = "Help",
  PROMPT = "Select a help tag",
  MAX_TOKENS = 2048,
  MAX_LINES = 128,
  --NOTE: On averege vimdoc line are 10-11 tokens long
}

---Find the tag row
---@param tag string The tag to find
---@param content string The content of the file
---@return integer The row of the tag
local function get_tag_row(tag, content)
  local ft = "vimdoc"
  local parser = vim.treesitter.get_string_parser(content, "vimdoc")
  local root = parser:parse()[1]:root()
  local query = ts.query.parse(ft, '((tag) @tag (#eq? @tag "*' .. tag .. '*"))')
  for _, node, _ in query:iter_captures(root, content) do
    local tag_row = node:range()
    return tag_row
  end
end

---Trim the content around the tag
---@param content string The content of the file
---@param tag string The tag to find
---@return string The trimmed content
local function trim_content(content, tag)
  local lines = vim.split(content, "\n")
  local tag_row = get_tag_row(tag, content)

  local prefix = ""
  local suffix = ""
  local start_, end_
  if tag_row - CONSTANTS.MAX_LINES / 2 < 1 then
    start_ = 1
    end_ = CONSTANTS.MAX_LINES
    suffix = "\n..."
  elseif tag_row + CONSTANTS.MAX_LINES / 2 > #lines then
    start_ = #lines - CONSTANTS.MAX_LINES
    end_ = #lines
    prefix = "...\n"
  else
    start_ = tag_row - CONSTANTS.MAX_LINES / 2
    end_ = tag_row + CONSTANTS.MAX_LINES / 2
    prefix = "...\n"
    suffix = "\n..."
  end

  content = table.concat(vim.list_slice(lines, start_, end_), "\n")
  local tokens = tokens_utils.calculate(content)
  assert(tokens < CONSTANTS.MAX_TOKENS, "The number of tokens exceeds the limit: " .. tokens)

  return prefix .. content .. suffix
end

---Output from the slash command in the chat buffer
---@param SlashCommand CodeCompanion.SlashCommand
---@param selected table The selected item from the provider { relative_path = string, path = string }
---@return nil
local function output(SlashCommand, selected)
  if not config.opts.send_code and (SlashCommand.config.opts and SlashCommand.config.opts.contains_code) then
    return log:warn("Sending of code has been disabled")
  end

  local ft = "vimdoc"
  local content = file_utils.read(selected.path)

  if content == "" then
    return log:warn("Could not read the file: %s", selected.path)
  end

  local tokens = tokens_utils.calculate(content)

  -- Add the whole help file
  if tokens > CONSTANTS.MAX_TOKENS then
    content = trim_content(content, selected.tag)
  end

  local Chat = SlashCommand.Chat
  local id = selected.tag

  Chat:add_message({
    role = config.constants.USER_ROLE,
    content = string.format(
      [[Here is some additional context related to the tag `%s`:

```%s
%s
```]],
      selected.tag,
      ft,
      content
    ),
  }, { reference = id, visible = false })

  Chat.References:add({
    source = "slash_command",
    name = "help",
    id = id,
  })

  util.notify(string.format("%s help file added to chat", selected.tag))
end

local Providers = {
  ---The Telescope provider
  ---@param SlashCommand CodeCompanion.SlashCommand
  ---@return nil
  telescope = function(SlashCommand)
    local ok, telescope = pcall(require, "telescope.builtin")
    if not ok then
      return log:error("Telescope is not installed")
    end

    telescope.help_tags({
      prompt_title = CONSTANTS.PROMPT,
      attach_mappings = function(prompt_bufnr, _)
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local selections = picker:get_multi_selection()

          if vim.tbl_isempty(selections) then
            selections = { action_state.get_selected_entry() }
          end

          actions.close(prompt_bufnr)
          vim.iter(selections):each(function(selection)
            if selection then
              selection = { path = selection.filename, tag = selection.display }
              output(SlashCommand, selection)
            end
          end)
        end)

        return true
      end,
    })
  end,

  ---@param SlashCommand CodeCompanion.SlashCommand
  ---@return nil
  mini_pick = function(SlashCommand)
    local ok, mini_pick = pcall(require, "mini.pick")
    if not ok then
      return log:error("mini.pick is not installed")
    end
    mini_pick.builtin.help({}, {
      source = {
        name = CONSTANTS.PROMPT,
        choose = function(selection)
          if selection == nil then
            return
          end
          output(SlashCommand, { path = selection.filename, tag = selection.name })
        end,
        choose_marked = function(selection)
          for _, selected in ipairs(selection) do
            local success, _ = pcall(function()
              output(SlashCommand, { path = selected.filename, tag = selected.name })
            end)
            if not success then
              break
            end
          end
        end,
      },
    })
  end,

  ---TODO: The fzf-lua provider
}

---@class CodeCompanion.SlashCommand.Help: CodeCompanion.SlashCommand
local SlashCommand = {}

---@param args CodeCompanion.SlashCommandArgs
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

---Execute the slash command
---@return nil
function SlashCommand:execute()
  if self.config.opts and self.config.opts.provider then
    local provider = Providers[self.config.opts.provider] --[[@type function]]
    if not provider then
      return log:error("Provider for the help slash command could not be found: %s", self.config.opts.provider)
    end
    provider(self)
  else
    Providers.telescope(self)
  end
end

return SlashCommand
