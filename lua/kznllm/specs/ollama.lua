local BaseProvider = require('kznllm.specs')
local utils = require('kznllm.utils')

local M = {}

---@class OllamaProvider : BaseProvider
---@field make_curl_args fun(self, opts: OllamaCurlOptions)
M.OllamaProvider = {}

---@param opts? BaseProviderOptions
---@return OllamaProvider
function M.OllamaProvider:new(opts)
  -- Call parent constructor with base options

  local o = opts or {}
  local instance = BaseProvider:new({
    base_url = o.base_url or 'http://localhost:11434',
  })

  -- Set proper metatable for inheritance
  setmetatable(instance, { __index = self })
  setmetatable(self, { __index = BaseProvider })

  ---silence lsp warning
  ---@type OllamaProvider
  return instance
end

---
--- TYPE ANNOTATIONS
---

---@class OllamaCurlOptions : OllamaHeaders
---@field data OllamaBody

---@class OllamaHeaders
---@field endpoint string
---@field auth_format? string
---@field extra_headers? string[]

---@class OllamaBody : OllamaParameters, OllamaPromptContext

---@class OllamaPromptContext
---@field messages OllamaMessage[]

---@class OllamaParameters
---@field model string
---@field max_tokens? integer
---@field max_completion_tokens? integer
---@field temperature? number
---@field top_p? number
---@field frequency_penalty? number
---@field presence_penalty? number

---@alias OllamaMessageRole "system" | "user" | "assistant"
---@class OllamaMessage
---@field role OllamaMessageRole
---@field content string | OllamaMessageContent[]

---@alias OllamaMessageContentType "text" | "image"
---@class OllamaMessageContent
---@field type OllamaMessageContentType
---@field text string

--- Process server-sent events based on Ollama spec
--- [See Documentation](https://github.com/ollama/ollama/blob/main/docs/api.md#generate-a-chat-completion)
---
---@param buf string
---@return string
function M.OllamaProvider.handle_sse_stream(buf)
  -- based on sse spec (Ollama spec uses data-only server-sent events)
  local content = ''

  for data in buf:gmatch('data: ({.-})\n') do
    -- if data and data:match '"delta":' then
    local json = vim.json.decode(data)
    -- sglang server returns the role as one of the events and it becomes `vim.NIL`, so we have to handle it here
    if json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
      content = content .. json.choices[1].delta.content
    else
      vim.print(data)
    end
    -- end
  end

  return content
end

---@class OllamaPresetConfig
---@field id string
---@field description string
---@field curl_options OllamaCurlOptions

---@class OllamaPresetSystemTemplate
---@field path string

---@class OllamaPresetMessageTemplate
---@field type OllamaMessageContentType
---@field role OllamaMessageRole
---@field path string

---@class OllamaPresetBuilder : BasePresetBuilder
---@field provider OllamaProvider
---@field system_templates OllamaPresetSystemTemplate[]
---@field message_templates OllamaPresetMessageTemplate[]
---@field debug_template? string
---@field headers OllamaHeaders
---@field params OllamaParameters
M.OllamaPresetBuilder = {}

local ollama_template_path = utils.join_path({ utils.TEMPLATE_PATH, 'ollama' })

---@param opts? { provider: OllamaProvider, headers: OllamaHeaders, params: OllamaParameters, debug_template_path: string }
---@return OllamaPresetBuilder
function M.OllamaPresetBuilder:new(opts)
  local o = opts or {}
  local instance = {
    provider = o.provider or M.OllamaProvider:new(),
    debug_template_path = o.debug_template_path or utils.join_path({ ollama_template_path, 'debug.xml.jinja' }),
    headers = o.headers or { endpoint = '/api/chat' },
    params = (opts and opts.params) and opts.params or {
      ['model'] = 'llama3.2',
    },
    system_templates = {},
    message_templates = {},
  }
  setmetatable(instance, { __index = self })
  return instance
end

---@param opts { params: OllamaParameters, headers: OllamaHeaders, provider: OllamaProvider }
function M.OllamaPresetBuilder:with_opts(opts)
  local cpy = vim.deepcopy(self)
  for k, v in pairs(opts) do
    cpy[k] = v
  end
  return cpy
end

---@param system_templates OllamaPresetSystemTemplate[]
function M.OllamaPresetBuilder:add_system_prompts(system_templates)
  for _, template in ipairs(system_templates) do
    table.insert(self.system_templates, 1, template)
  end
  return self
end

---@param message_templates OllamaPresetMessageTemplate[]
function M.OllamaPresetBuilder:add_message_prompts(message_templates)
  for _, template in ipairs(message_templates) do
    table.insert(self.message_templates, template)
  end
  return self
end

---@return OllamaCurlOptions
function M.OllamaPresetBuilder:build(args)
  ---@type OllamaMessage[]
  local messages = {}

  for _, template in ipairs(self.system_templates) do
    table.insert(messages, {
      role = 'system',
      content = utils.make_prompt_from_template({ template_path = template.path, prompt_args = args }),
    })
  end

  for _, template in ipairs(self.message_templates) do
    if template.type == 'text' then
      local message_content = {
        type = template.type,
        text = utils.make_prompt_from_template({ template_path = template.path, prompt_args = args }),
      }

      table.insert(messages, {
        role = template.role,
        content = { message_content },
      })
    end
  end

  return vim.tbl_extend('keep', self.headers, {
    data = vim.tbl_extend('keep', self.params, { messages = messages }),
  })
end

return M
