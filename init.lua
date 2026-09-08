local obj = {}
obj.__index = obj

obj.name = "HandyTextReplacements"
obj.version = "2.2.0"
obj.author = "Nabeel"
obj.license = "MIT"

obj.configPath = hs.spoons.resourcePath("config.json")
obj.replacementConfigPath = hs.spoons.resourcePath("replacements.json")
obj.bridgePath = hs.spoons.resourcePath("handy-text-replacements")
obj.logger = hs.logger.new("HandyReplacements", "info")

local HANDY_BUNDLE_ID = "com.pais.handy"
local LOG_LEVELS = {
    nothing = true,
    error = true,
    warning = true,
    info = true,
    debug = true,
    verbose = true,
}

local function readJson(path)
    local file, openError = io.open(path, "r")
    if not file then
        return nil, openError
    end
    local contents = file:read("*a")
    file:close()

    local ok, value = pcall(hs.json.decode, contents)
    if not ok or type(value) ~= "table" then
        return nil, ok and "JSON root must be an object or array" or tostring(value)
    end
    return value
end

local function validateConfig(raw)
    local restore = raw.restore_clipboard
    local delay = raw.restore_delay_seconds
    local configure = raw.configure_handy_on_start
    local level = raw.log_level or "info"

    if restore ~= nil and type(restore) ~= "boolean" then
        return nil, "restore_clipboard must be a boolean"
    end
    if delay ~= nil and (type(delay) ~= "number" or delay < 0) then
        return nil, "restore_delay_seconds must be a non-negative number"
    end
    if configure ~= nil and type(configure) ~= "boolean" then
        return nil, "configure_handy_on_start must be a boolean"
    end
    if type(level) ~= "string" or not LOG_LEVELS[level] then
        return nil, "invalid log_level"
    end

    return {
        restore_clipboard = restore ~= false,
        restore_delay_seconds = delay or 0.25,
        configure_handy_on_start = configure ~= false,
        log_level = level,
    }
end

local function handySettingsPath()
    return os.getenv("HOME")
        .. "/Library/Application Support/"
        .. HANDY_BUNDLE_ID
        .. "/settings_store.json"
end

local function writeJsonAtomically(value, path)
    local temporaryPath = path .. ".hammerspoon-tmp"
    if not hs.json.write(value, temporaryPath, true, true) then
        return false, "could not write temporary settings"
    end
    local ok, renameError = os.rename(temporaryPath, path)
    if not ok then
        os.remove(temporaryPath)
        return false, renameError
    end
    return true
end

function obj:_settingsMatch(store)
    local settings = type(store) == "table" and store.settings or nil
    return type(settings) == "table"
        and settings.paste_method == "external_script"
        and settings.clipboard_handling == "dont_modify"
        and settings.external_script_path == self.bridgePath
end

function obj:_writeHandySettings()
    local path = handySettingsPath()
    local store, readError = readJson(path)
    if not store or type(store.settings) ~= "table" then
        return false, "could not read Handy settings: " .. tostring(readError)
    end
    if self:_settingsMatch(store) then
        return true
    end

    store.settings.paste_method = "external_script"
    store.settings.clipboard_handling = "dont_modify"
    store.settings.external_script_path = self.bridgePath
    return writeJsonAtomically(store, path)
end

function obj:_finishHandyConfiguration(relaunch)
    local ok, errorMessage = self:_writeHandySettings()
    if not ok then
        self.logger.e(errorMessage)
    end
    if relaunch and not hs.application.launchOrFocusByBundleID(HANDY_BUNDLE_ID) then
        self.logger.e("Could not relaunch Handy")
    end
end

function obj:configureHandy()
    if self._configureTimer or not hs.fs.attributes(self.bridgePath) then
        return self
    end

    local store = readJson(handySettingsPath())
    if self:_settingsMatch(store) then
        return self
    end

    local app = hs.application.get(HANDY_BUNDLE_ID)
    if not app then
        self:_finishHandyConfiguration(false)
        return self
    end

    local checks = 0
    app:kill()
    self._configureTimer = hs.timer.doEvery(0.1, function()
        checks = checks + 1
        if not hs.application.get(HANDY_BUNDLE_ID) then
            self._configureTimer:stop()
            self._configureTimer = nil
            self:_finishHandyConfiguration(true)
        elseif checks >= 50 then
            self._configureTimer:stop()
            self._configureTimer = nil
            self.logger.e("Timed out waiting for Handy to quit")
        end
    end)
    return self
end

function obj:reload()
    local raw, readError = readJson(self.configPath)
    if not raw then
        self.logger.e("Could not load configuration: " .. tostring(readError))
        return self
    end

    local config, configError = validateConfig(raw)
    if not config then
        self.logger.e("Invalid configuration: " .. configError)
        return self
    end

    self.config = config
    self.logger.setLogLevel(config.log_level)
    return self
end

function obj:process(text)
    local raw, readError = readJson(self.replacementConfigPath)
    if not raw then
        return nil, "could not load replacements: " .. tostring(readError)
    end

    local rules, errors = self.engine.validateConfig(raw)
    if not rules then
        return nil, table.concat(errors, "; ")
    end
    for _, warning in ipairs(errors) do
        self.logger.w(warning)
    end
    return self.engine.processValidated(text, rules)
end

function obj:_restoreClipboard(expectedChangeCount)
    if self._restoreTimer then
        self._restoreTimer:stop()
        self._restoreTimer = nil
    end

    local snapshot = self._clipboardSnapshot
    self._clipboardSnapshot = nil
    if not snapshot or hs.pasteboard.changeCount() ~= expectedChangeCount then
        return
    end
    if snapshot.empty then
        hs.pasteboard.clearContents()
    else
        hs.pasteboard.writeAllData(snapshot.data)
    end
end

function obj:receiveExternalText(text)
    if type(text) ~= "string" or text == "" then
        return "error: transcription is empty"
    end

    local processed, statsOrError = self:process(text)
    if not processed or processed == "" then
        return "error: " .. tostring(statsOrError or "replacement result is empty")
    end

    if self._clipboardSnapshot then
        self:_restoreClipboard(hs.pasteboard.changeCount())
    end
    if self.config.restore_clipboard then
        local ok, data = pcall(hs.pasteboard.readAllData)
        if ok and data == nil then
            data = {}
        end
        if ok and type(data) == "table" then
            self._clipboardSnapshot = {data = data, empty = next(data) == nil}
        end
    end

    if not hs.pasteboard.setContents(processed) then
        self:_restoreClipboard(hs.pasteboard.changeCount())
        return "error: could not set clipboard"
    end
    local changeCount = hs.pasteboard.changeCount()
    local pasted, pasteError = pcall(hs.eventtap.keyStroke, {"cmd"}, "v", 0)
    if not pasted then
        self:_restoreClipboard(changeCount)
        return "error: could not paste: " .. tostring(pasteError)
    end

    if self._clipboardSnapshot then
        self._restoreTimer = hs.timer.doAfter(
            self.config.restore_delay_seconds,
            function()
                self:_restoreClipboard(changeCount)
            end
        )
    end

    local stats = statsOrError or {}
    self.logger.d(string.format(
        "Processed transcription (%d rules, %d matches)",
        stats.rulesApplied or 0,
        stats.matches or 0
    ))
    return "ok"
end

function obj:receiveExternalBase64(encoded)
    if type(encoded) ~= "string" then
        return "error: encoded transcription is missing"
    end
    local ok, decoded = pcall(hs.base64.decode, encoded)
    if not ok or type(decoded) ~= "string" then
        return "error: invalid base64 transcription"
    end
    return self:receiveExternalText(decoded)
end

function obj:init()
    self.engine = dofile(hs.spoons.resourcePath("engine.lua"))
    self:reload()
    return self
end

function obj:start()
    if self.config.configure_handy_on_start then
        self:configureHandy()
    end
    return self
end

function obj:stop()
    for _, timer in ipairs({self._configureTimer, self._restoreTimer}) do
        if timer then
            timer:stop()
        end
    end
    self._configureTimer = nil
    self._restoreTimer = nil
    self._clipboardSnapshot = nil
    return self
end

function obj:runTests()
    return self.engine.runTests()
end

return obj
