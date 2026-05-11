-- Server-driven Jira issue creation via createmeta API
-- Fetches issue types and fields from server, classifies them, generates templates,
-- and extracts values back on save.
local M = {}

local api = require("jira-interface.api")
local cache = require("jira-interface.cache")
local config = require("jira-interface.config")
local bridge = require("atlassian.csf.bridge")

-- =============================================================================
-- Field categories
-- =============================================================================

---@alias FieldCategory "summary"|"rich_text"|"picker"|"text_line"|"skip"

---@class ClassifiedField
---@field fieldId string
---@field name string
---@field required boolean
---@field category FieldCategory
---@field schema table
---@field allowedValues? table[]

---@class ClassifiedFields
---@field summary ClassifiedField|nil
---@field rich_text ClassifiedField[]
---@field picker ClassifiedField[]
---@field text_line ClassifiedField[]
---@field skip ClassifiedField[]

-- Fields that are auto-handled or not user-editable in the create buffer
local SKIP_FIELDS = {
    project = true,
    issuetype = true,
    reporter = true,
    assignee = true,
    status = true,
    resolution = true,
    attachment = true,
    comment = true,
    issuelinks = true,
    created = true,
    updated = true,
    creator = true,
    worklog = true,
    timetracking = true,
    security = true,
    votes = true,
    watches = true,
    thumbnail = true,
    workratio = true,
    subtasks = true,
    aggregatetimeestimate = true,
    aggregatetimeoriginalestimate = true,
    aggregatetimespent = true,
    aggregateprogress = true,
    progress = true,
    environment = true,
    duedate = false, -- handled as text_line
    parent = true,   -- handled separately in picker flow
}

---@param field CreateMetaField
---@return FieldCategory
function M.classify_field(field)
    local id = field.fieldId

    -- summary is always the h1 title
    if id == "summary" then
        return "summary"
    end

    -- Skip auto-handled fields
    if SKIP_FIELDS[id] then
        return "skip"
    end

    local schema = field.schema or {}
    local schema_type = schema.type or ""
    local schema_system = schema.system or ""
    local schema_custom = schema.custom or ""

    -- Rich text: description and ADF-type custom fields
    if id == "description" then
        return "rich_text"
    end
    if schema_custom:match("textarea") or schema_type == "doc" then
        return "rich_text"
    end

    -- Picker: fields with allowedValues (priority, components, fix versions, selects)
    if field.allowedValues and #field.allowedValues > 0 then
        return "picker"
    end

    -- Special system fields with known picker behavior
    if schema_system == "priority" or schema_system == "components"
        or schema_system == "fixVersions" or schema_system == "versions" then
        return "picker"
    end

    -- Text line: labels, dates, strings, numbers
    if schema_system == "labels" or schema_type == "date" or schema_type == "datetime"
        or schema_type == "string" or schema_type == "number" then
        return "text_line"
    end

    -- Array of strings (e.g., labels)
    if schema_type == "array" and schema.items == "string" then
        return "text_line"
    end

    -- Required fields we don't recognize: treat as rich_text so they appear in the buffer
    if field.required then
        return "rich_text"
    end

    -- Default: skip unknown complex types
    return "skip"
end

---@param fields CreateMetaField[]
---@return ClassifiedFields
function M.classify_all(fields)
    local result = {
        summary = nil,
        rich_text = {},
        picker = {},
        text_line = {},
        skip = {},
    }

    for _, field in ipairs(fields) do
        local category = M.classify_field(field)
        local classified = {
            fieldId = field.fieldId,
            name = field.name,
            required = field.required,
            category = category,
            schema = field.schema or {},
            allowedValues = field.allowedValues,
        }

        if category == "summary" then
            result.summary = classified
        else
            table.insert(result[category], classified)
        end
    end

    -- Sort: required fields first within each category
    for _, cat in ipairs({ "rich_text", "picker", "text_line" }) do
        table.sort(result[cat], function(a, b)
            if a.required ~= b.required then
                return a.required
            end
            return a.name < b.name
        end)
    end

    return result
end

-- =============================================================================
-- Template generation
-- =============================================================================

---@param classified ClassifiedFields
---@param issue_type_name string
---@return string[] lines CSF buffer lines (without metadata)
function M.generate_template(classified, issue_type_name)
    local lines = {}

    -- h1 title with issue type name as placeholder
    table.insert(lines, "<h1>" .. issue_type_name .. "</h1>")

    -- Rich text sections as h2
    for _, field in ipairs(classified.rich_text) do
        table.insert(lines, "<h2>" .. field.name .. "</h2>")
        table.insert(lines, "<p></p>")
    end

    -- Text line fields in a Fields section
    if #classified.text_line > 0 then
        table.insert(lines, "<h2>Fields</h2>")
        for _, field in ipairs(classified.text_line) do
            local hint = M.get_field_hint(field)
            if hint then
                table.insert(lines, "<p><strong>" .. field.name .. ":</strong>  <em>(" .. hint .. ")</em></p>")
            else
                table.insert(lines, "<p><strong>" .. field.name .. ":</strong> </p>")
            end
        end
    end

    table.insert(lines, "<hr />")
    return lines
end

---@param field ClassifiedField
---@return string|nil hint text
function M.get_field_hint(field)
    local schema = field.schema or {}
    local schema_type = schema.type or ""
    local schema_system = schema.system or ""

    if schema_type == "date" or schema_type == "datetime" or schema_system == "duedate" then
        return "YYYY-MM-DD"
    end
    if schema_system == "labels" or (schema_type == "array" and schema.items == "string") then
        return "comma-separated"
    end
    if schema_type == "number" then
        return "number"
    end
    return nil
end

-- =============================================================================
-- Value extraction from buffer
-- =============================================================================

---@param buf number Buffer handle
---@param classified ClassifiedFields
---@return table fields Jira API fields table
function M.extract_fields_from_buffer(buf, classified)
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Remove metadata line
    table.remove(content, 1)

    -- Extract summary from h1
    local summary_text, remaining = csf.extract_title(content)
    content = remaining

    local fields = {}
    if summary_text and summary_text ~= "" then
        fields.summary = summary_text
    end

    -- Build section names for extract_sections
    local section_names = {}
    local rich_text_map = {} -- normalized_name → field
    for _, field in ipairs(classified.rich_text) do
        local normalized = field.name:lower():gsub("%s+", "_")
        table.insert(section_names, normalized)
        rich_text_map[normalized] = field
    end

    -- Add "fields" section for text_line extraction
    if #classified.text_line > 0 then
        table.insert(section_names, "fields")
    end

    local parsed = csf.extract_sections(content, section_names)

    -- Convert rich text sections to ADF
    for normalized, field in pairs(rich_text_map) do
        if parsed[normalized] and parsed[normalized] ~= "" then
            local adf = bridge.sanitize_for_jira(bridge.csf_to_adf(parsed[normalized]))
            fields[field.fieldId] = adf
        end
    end

    -- Extract text line fields from the Fields section
    if parsed.fields and parsed.fields ~= "" then
        M.extract_text_line_fields(parsed.fields, classified.text_line, fields)
    end

    return fields
end

---@param fields_section_csf string Raw CSF of the Fields section
---@param text_line_fields ClassifiedField[]
---@param out table Output fields table to populate
function M.extract_text_line_fields(fields_section_csf, text_line_fields, out)
    for _, field in ipairs(text_line_fields) do
        -- Match <strong>Field Name:</strong> value</p>
        -- The value is everything between :</strong> and </p>, trimmed
        local pattern = "<strong>" .. vim.pesc(field.name) .. ":</strong>%s*(.-)%s*</p>"
        local raw_value = fields_section_csf:match(pattern)

        if raw_value then
            -- Strip only unchanged hint placeholders (exact match)
            local hint = M.get_field_hint(field)
            if hint then
                raw_value = raw_value:gsub("<em>%(" .. vim.pesc(hint) .. "%)%s*</em>", "")
            end
            -- Unwrap remaining <em>(...)</em> where user replaced hint with actual value
            raw_value = raw_value:gsub("<em>%((.-)%)</em>", "%1")
            -- Also unwrap plain <em>...</em>
            raw_value = raw_value:gsub("<em>(.-)</em>", "%1")
            raw_value = vim.trim(raw_value)

            if raw_value ~= "" then
                out[field.fieldId] = M.serialize_text_value(field, raw_value)
            end
        end
    end
end

---@param field ClassifiedField
---@param raw_value string
---@return any Serialized value for Jira API
function M.serialize_text_value(field, raw_value)
    local schema = field.schema or {}
    local schema_type = schema.type or ""
    local schema_system = schema.system or ""

    -- Date fields: pass as-is string
    if schema_type == "date" or schema_type == "datetime" or schema_system == "duedate" then
        return raw_value
    end

    -- Number fields
    if schema_type == "number" then
        return tonumber(raw_value) or raw_value
    end

    -- Labels / array of strings: comma-split
    if schema_system == "labels" or (schema_type == "array" and schema.items == "string") then
        local values = {}
        for item in raw_value:gmatch("[^,]+") do
            local trimmed = vim.trim(item)
            if trimmed ~= "" then
                table.insert(values, trimmed)
            end
        end
        return values
    end

    -- Default: plain string
    return raw_value
end

-- =============================================================================
-- Picker value serialization
-- =============================================================================

---@param field ClassifiedField
---@param selected table The selected allowedValue item (has .id, .name, etc.)
---@return any Serialized value for Jira API
function M.serialize_picker_value(field, selected)
    local schema = field.schema or {}
    local schema_type = schema.type or ""

    -- Array types (components, fixVersions, multi-select): wrap in array
    if schema_type == "array" then
        return { { id = selected.id } }
    end

    -- Single option: { id = "..." }
    return { id = selected.id }
end

-- =============================================================================
-- Fetching with cache
-- =============================================================================
-- ADF-based template and extraction (projection editor)
-- =============================================================================

---@param classified ClassifiedFields
---@param issue_type_name string
---@return table ADF document
---@return table section_map
function M.generate_template_adf(classified, issue_type_name)
    local content = {}
    local section_map = {}

    -- Title heading
    table.insert(content, {
        type = "heading", attrs = { level = 1 },
        content = { { type = "text", text = issue_type_name } },
    })
    section_map[#content] = { field = "summary" }

    -- Rich text sections
    for _, field in ipairs(classified.rich_text) do
        table.insert(content, {
            type = "heading", attrs = { level = 2 },
            content = { { type = "text", text = field.name } },
        })
        local start_idx = #content + 1
        table.insert(content, {
            type = "paragraph",
            content = { { type = "text", text = "" } },
        })
        section_map[start_idx] = { field = field.fieldId, end_idx = #content }
    end

    -- Text line fields as bold label: value paragraphs
    if #classified.text_line > 0 then
        table.insert(content, { type = "rule" })
        table.insert(content, {
            type = "heading", attrs = { level = 2 },
            content = { { type = "text", text = "Fields" } },
        })
        local fields_start = #content + 1
        for _, field in ipairs(classified.text_line) do
            local hint = M.get_field_hint(field)
            local value_text = hint and ("(" .. hint .. ")") or ""
            table.insert(content, {
                type = "paragraph",
                content = {
                    { type = "text", text = field.name .. ": ", marks = { { type = "strong" } } },
                    { type = "text", text = value_text },
                },
            })
        end
        section_map[fields_start] = { field = "_text_lines", end_idx = #content }
    end

    return { type = "doc", version = 1, content = content }, section_map
end

---@param adf table ADF document
---@param section_map table
---@param classified ClassifiedFields
---@return table fields Jira API fields table
function M.extract_fields_from_adf(adf, section_map, classified)
    local fields = {}
    local content = adf.content or {}

    for start_idx, section in pairs(section_map) do
        if section.field == "summary" then
            local node = content[start_idx]
            if node and node.content then
                local texts = {}
                for _, child in ipairs(node.content) do
                    if child.type == "text" then texts[#texts + 1] = child.text or "" end
                end
                local summary = table.concat(texts)
                if summary ~= "" then fields.summary = summary end
            end
        elseif section.field == "_text_lines" then
            -- Extract text line values from bold-label paragraphs
            local end_idx = section.end_idx or start_idx
            for i = start_idx, end_idx do
                local node = content[i]
                if node and node.type == "paragraph" and node.content then
                    -- Find the field name from the bold text
                    local field_name, value_text
                    for _, child in ipairs(node.content) do
                        if child.marks then
                            for _, mark in ipairs(child.marks) do
                                if mark.type == "strong" then
                                    field_name = (child.text or ""):gsub(":%s*$", "")
                                end
                            end
                        elseif child.type == "text" and not child.marks then
                            value_text = child.text or ""
                        end
                    end
                    if field_name and value_text then
                        value_text = value_text:gsub("^%s*%(.*%)%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if value_text ~= "" then
                            -- Find matching field
                            for _, f in ipairs(classified.text_line) do
                                if f.name == field_name then
                                    fields[f.fieldId] = M.serialize_text_value(f, value_text)
                                    break
                                end
                            end
                        end
                    end
                end
            end
        else
            -- Rich text field: collect ADF nodes
            local end_idx = section.end_idx or start_idx
            local section_content = {}
            for i = start_idx, end_idx do
                if content[i] then table.insert(section_content, content[i]) end
            end
            local section_adf = { type = "doc", version = 1, content = section_content }
            fields[section.field] = bridge.sanitize_for_jira(section_adf)
        end
    end

    return fields
end

-- =============================================================================

---@param project_key string
---@param callback fun(err: string|nil, types: CreateMetaIssueType[]|nil)
function M.get_issue_types(project_key, callback)
    local cache_key = "createmeta_types_" .. project_key
    cache.get_or_fetch(cache_key, function(cb)
        api.get_create_issue_types(project_key, cb)
    end, callback, project_key)
end

---@param project_key string
---@param issue_type_id string
---@param callback fun(err: string|nil, fields: CreateMetaField[]|nil)
function M.get_fields(project_key, issue_type_id, callback)
    local cache_key = "createmeta_fields_" .. project_key .. "_" .. issue_type_id
    cache.get_or_fetch(cache_key, function(cb)
        api.get_create_fields(project_key, issue_type_id, cb)
    end, callback, project_key)
end

return M
