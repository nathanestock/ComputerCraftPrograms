local args = { ... }

local CONFIG_PATH = "pull_config.json"
local GITHUB_REPO_URL = "https://github.com/nathanestock/ComputerCraftPrograms"
local GITHUB_BRANCH = "main"
local PULL_PROGRAM_NAME = "pull"
local PULL_PASTEBIN_ID = "KGKJTSgs"

local DEFAULT_CONFIG = {
    ["ccmine"] = "",
    ["turtle_manager"] = "8twqeysK",
    ["ratio_block"] = "3YDJda7k",
    ["machine_manager"] = "",
    ["airship"] = "",
    ["plib"] = "",
    ["helicopter"] = "",
    ["memorial_raft"] = "",
    ["tlib"] = ""
}

local function printUsage()
    print("Usage:")
    print("  pull init")
    print("  pull refresh-pull")
    print("  pull -r")
    print("  pull use-github <program_name>")
    print("  pull -g <program_name>")
    print("  pull use-pastebin <program_name> [pastebin_id]")
    print("  pull -p <program_name> [pastebin_id]")
    print("  pull audit")
    print("  pull -a")
    print("  pull <program_name>")
end

if #args == 0 then
    printUsage()
    return
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function startsWith(value, prefix)
    return value:sub(1, #prefix) == prefix
end

local function getRawRepoBase(repoUrl, branch)
    local owner, repo = repoUrl:match("^https?://github%.com/([^/]+)/([^/]+)/?$")
    if not owner or not repo then
        return nil
    end
    return "https://raw.githubusercontent.com/" .. owner .. "/" .. repo .. "/" .. branch .. "/"
end

local function safeReplace(targetPath, tempPath)
    if fs.exists(targetPath) then
        fs.delete(targetPath)
    end
    fs.move(tempPath, targetPath)
end

local function downloadFromHttp(url, targetPath)
    if not http then
        printError("HTTP API is unavailable on this computer/server.")
        return false
    end

    local response, err = http.get(url)
    if not response then
        printError("Failed to fetch URL: " .. (err or "unknown error"))
        return false
    end

    local body = response.readAll()
    response.close()

    if not body or body == "" then
        printError("Downloaded file was empty.")
        return false
    end

    local tempPath = targetPath .. ".tmp_pull"
    if fs.exists(tempPath) then
        fs.delete(tempPath)
    end

    local file = fs.open(tempPath, "w")
    if not file then
        printError("Could not open temp file for writing: " .. tempPath)
        return false
    end

    file.write(body)
    file.close()
    safeReplace(targetPath, tempPath)
    return true
end

local function downloadFromPastebin(pasteId, targetPath)
    local tempPath = targetPath .. ".tmp_pull"
    if fs.exists(tempPath) then
        fs.delete(tempPath)
    end

    local ok = shell.run("pastebin", "get", pasteId, tempPath)
    if not ok then
        if fs.exists(tempPath) then
            fs.delete(tempPath)
        end
        return false
    end

    safeReplace(targetPath, tempPath)
    return true
end

local function readConfig()
    if not fs.exists(CONFIG_PATH) then
        return nil, "Config not found. Run 'pull init' first."
    end

    local file = fs.open(CONFIG_PATH, "r")
    if not file then
        return nil, "Failed to open " .. CONFIG_PATH
    end

    local config = textutils.unserializeJSON(file.readAll())
    file.close()

    if type(config) ~= "table" then
        return nil, "Invalid config JSON. Run 'pull init' or fix " .. CONFIG_PATH
    end

    return config
end

local function writeConfig(config)
    local file = fs.open(CONFIG_PATH, "w")
    if not file then
        return false
    end

    file.write(textutils.serializeJSON(config))
    file.close()
    return true
end

local function updateProgram(programName, sourceValue)
    local success = false

    if sourceValue == "" then
        local rawBase = getRawRepoBase(GITHUB_REPO_URL, GITHUB_BRANCH)
        if not rawBase then
            printError("Invalid GitHub repo URL configured in script.")
            return false
        end

        local rawUrl = rawBase .. programName .. ".lua"
        success = downloadFromHttp(rawUrl, programName)
    elseif startsWith(sourceValue, "http://") or startsWith(sourceValue, "https://") then
        success = downloadFromHttp(sourceValue, programName)
    else
        success = downloadFromPastebin(sourceValue, programName)
    end

    return success
end

local function sourceLabel(sourceValue)
    if sourceValue == "" then
        return "github(default)"
    end

    if startsWith(sourceValue, "http://") or startsWith(sourceValue, "https://") then
        return "http(url)"
    end

    return "pastebin(id)"
end

local function sortedKeys(map)
    local keys = {}
    for key, _ in pairs(map) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

local function runAudit()
    local config, err = readConfig()
    if not config then
        printError(err)
        return
    end

    local keys = sortedKeys(config)
    print("Pull config audit:")

    for i = 1, #keys do
        local name = keys[i]
        local value = config[name]

        if type(value) == "string" then
            local trimmed = trim(value)
            print("  " .. name .. " -> " .. sourceLabel(trimmed))
        else
            print("  " .. name .. " -> invalid(non-string)")
        end
    end
end

-- Logic for 'init'
if args[1] == "init" then
    if not writeConfig(DEFAULT_CONFIG) then
        printError("Failed to write " .. CONFIG_PATH)
        return
    end

    print("Created pull_config.json with default mappings.")
    return
end

local command = args[1]
if command == "-r" then
    command = "refresh-pull"
elseif command == "-g" then
    command = "use-github"
elseif command == "-p" then
    command = "use-pastebin"
elseif command == "-a" then
    command = "audit"
elseif startsWith(command, "-") then
    printError("Unknown flag: " .. command)
    printUsage()
    return
end

if command == "audit" then
    runAudit()
    return
end

if command == "use-github" then
    local programName = args[2]
    if not programName or trim(programName) == "" then
        printError("Usage: pull use-github <program_name>")
        return
    end

    local config, err = readConfig()
    if not config then
        printError(err)
        return
    end

    config[programName] = ""
    if not writeConfig(config) then
        printError("Failed to write " .. CONFIG_PATH)
        return
    end

    print("Set '" .. programName .. "' to GitHub mode (empty value fallback).")
    return
end

if command == "use-pastebin" then
    local programName = args[2]
    if not programName or trim(programName) == "" then
        printError("Usage: pull use-pastebin <program_name> [pastebin_id]")
        return
    end

    local pastebinId = args[3]
    if not pastebinId or trim(pastebinId) == "" then
        pastebinId = DEFAULT_CONFIG[programName]
    end

    if not pastebinId or trim(pastebinId) == "" then
        printError("No Pastebin ID available. Provide one: pull use-pastebin <program_name> <pastebin_id>")
        return
    end

    local config, err = readConfig()
    if not config then
        printError(err)
        return
    end

    config[programName] = trim(pastebinId)
    if not writeConfig(config) then
        printError("Failed to write " .. CONFIG_PATH)
        return
    end

    print("Set '" .. programName .. "' to Pastebin ID '" .. trim(pastebinId) .. "'.")
    return
end

if command == "refresh-pull" then
    print("Refreshing pull program...")

    local rawBase = getRawRepoBase(GITHUB_REPO_URL, GITHUB_BRANCH)
    if rawBase then
        local githubUrl = rawBase .. PULL_PROGRAM_NAME .. ".lua"
        if downloadFromHttp(githubUrl, PULL_PROGRAM_NAME) then
            print("Success: pull updated from GitHub.")
            return
        end

        printError("GitHub update failed; falling back to Pastebin.")
    else
        printError("Invalid GitHub repo URL configured; falling back to Pastebin.")
    end

    if downloadFromPastebin(PULL_PASTEBIN_ID, PULL_PROGRAM_NAME) then
        print("Success: pull updated from Pastebin fallback.")
        return
    end

    printError("Failed to refresh pull from both GitHub and Pastebin.")
    return
end

local programName = command
if not programName or trim(programName) == "" then
    printUsage()
    return
end

local config, err = readConfig()
if not config then
    printError(err)
    return
end

local sourceValue = config[programName]
if sourceValue == nil then
    printError("Program '" .. programName .. "' not found in config.")
    return
end

if type(sourceValue) ~= "string" then
    printError("Program config for '" .. programName .. "' must be a string value.")
    return
end

sourceValue = trim(sourceValue)

-- Update Process
print("Updating " .. programName .. "...")
if updateProgram(programName, sourceValue) then
    print("Success: " .. programName .. " updated.")
else
    printError("Update failed for '" .. programName .. "'.")
end
