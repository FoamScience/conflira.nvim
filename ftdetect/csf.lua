vim.filetype.add({
    pattern = {
        ["csf://.*"] = "csf",
        ["confluence_storage:.*"] = "csf",
        ["confluence://.*"] = "csf",
        ["jira://.*"] = "csf",
    },
    extension = { csf = "csf" },
})
