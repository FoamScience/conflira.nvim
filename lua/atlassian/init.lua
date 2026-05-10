-- Shared Atlassian utilities for jira-interface and confluence-interface
local M = {}

M.notify = require("atlassian.notify")
M.request = require("atlassian.request")
M.error = require("atlassian.error")
M.ui = require("atlassian.ui")
M.cache = require("atlassian.cache")
M.format = require("atlassian.format")
M.adf = require("atlassian.adf")
M.image = require("atlassian.image")
M.editor = require("atlassian.editor")

return M
