local micro = import("micro")
local shell = import("micro/shell")
local buffer = import("micro/buffer")
local config = import("micro/config")
local fmt = import("fmt")
local utf = import("unicode/utf8")

config.RegisterCommonOption("aspell", "check", "auto")
config.RegisterCommonOption("aspell", "lang", "")
config.RegisterCommonOption("aspell", "dict", "")
config.RegisterCommonOption("aspell", "sugmode", "normal")
config.RegisterCommonOption("aspell", "args", "")

function init()
    config.MakeCommand("addpersonal", addpersonal, config.NoComplete)
    config.AddRuntimeFile("aspell", config.RTHelp, "help/aspell.md")
end

local patterns = {"^# (.-) (%d+)$", "^& (.-) %d+ (%d+): (.+)$"}

local filterModes = {
    xml = "sgml",
    ["c++"] = "ccpp",
    c = "ccpp",
    html = "html",
    html4 = "html",
    html5 = "html",
    perl = "perl",
    perl6 = "perl",
    tex = "tex",
    markdown = "markdown",
    -- Aspell has comment mode, in which only lines starting with # are checked
    -- but it doesn't work for some reason
}

local lock = false
local next = nil

function runAspell(buf, onExit)
    local text = fmt.Sprintf("%s", buf.SharedBuffer.LineArray:Bytes())

    -- Escape for aspell (it interprets lines that start
    -- with % @ ^ ! etc.)
    text = text:gsub("\n", "\n^"):gsub("^", "^")
    -- Enable terse mode
    text = "!\n" .. text
    -- Escape for shell
    text = "'" .. text:gsub("'", "'\\''") .. "'"

    local options = ""
    -- FIXME: we should support non-utf8 encodings with '--encoding'
    if filterModes[buf:FileType()] then
        options = options .. " --mode=" .. filterModes[buf:FileType()]
    end
    if buf.Settings["aspell.lang"] ~= "" then
        options = options .. " --lang=" .. buf.Settings["aspell.lang"]
    end
    if buf.Settings["aspell.dict"] ~= "" then
        options = options .. " --master=" .. buf.Settings["aspell.dict"]
    end
    if buf.Settings["aspell.sugmode"] ~= "" then
        options = options .. " --sug-mode=" .. buf.Settings["aspell.sugmode"]
    end
    if buf.Settings["aspell.args"] ~= "" then
        options = options .. " " .. buf.Settings["aspell.args"]
    end

    shell.JobStart("echo " .. text .. " | aspell pipe" .. options, nil,
            nil, onExit, buf)
end

function spellcheck(bp)
    if bp ~= nil then
        local check = bp.Buf.Settings["aspell.check"]
        if check == "on" or (check == "auto" and filterModes[bp.Buf:FileType()]) then
            if lock then
                next = bp
            else
                lock = true
                runAspell(bp.Buf, highlight)
            end
        else
            -- If we aren't supposed to spellcheck, clear the messages
            bp.Buf:ClearMessages("aspell")
        end
    end
end

function highlight(out, args)
    local buf = args[1]

    if out:find("command not found") then
        micro.InfoBar():Error(
                "Make sure that Aspell is installed and available in your PATH")
    elseif not out:find("International Ispell Version") then
        -- Something went wrong, we'll show what Aspell has to say
        micro.InfoBar():Error("Aspell: " .. out)
    end

    lock = false

    buf:ClearMessages("aspell")

    -- This is a hack that keeps the text shifted two columns to the right
    -- even when no gutter messages are shown
    local msg = "This message shouldn't be visible (Aspell plugin)"
    local bmsg = buffer.NewMessageAtLine("aspell", msg, 0, buffer.MTError)
    buf:AddMessage(bmsg)

    local linenumber = 1
    local lines = split(out, "\n")
    for _, line in ipairs(lines) do
        if line == "" then
            linenumber = linenumber + 1
        else
            for _, pattern in ipairs(patterns) do
                if string.find(line, pattern) then
                    local word, offset, suggestions = string.match(line, pattern)
                    offset = tonumber(offset)
                    local msg = nil
                    if suggestions then
                        msg = word .. " -> " .. suggestions
                    else
                        msg = word .. " ->X"
                    end

                    local mlen = utf.RuneCountInString(word)
                    local mstart = buffer.Loc(offset - 1, linenumber - 1)
                    local mend = buffer.Loc(offset - 1 + mlen, linenumber - 1)
                    local bmsg = buffer.NewMessage("aspell", msg, mstart,
                            mend, buffer.MTWarning)
                    buf:AddMessage(bmsg)
                end
            end
        end
    end

    if next ~= nil then
        spellcheck(next)
        next = nil
    end
end

function addpersonal(bp)
    local check = bp.Buf.Settings["aspell.check"]
    if check == "on" or (check == "auto" and filterModes[bp.Buf:FileType()]) then
        runAspell(bp.Buf, addpersonal2)
    end
end

function addpersonal2(out, args)
    local buf = args[1]
    local loc = buf:GetActiveCursor().Loc

    local linenumber = 1
    local lines = split(out, "\n")
    for _, line in ipairs(lines) do
        if line == "" then
            linenumber = linenumber + 1
        else
            for _, pattern in ipairs(patterns) do
                if string.find(line, pattern) then
                    local word, offset, suggestions = string.match(line, pattern)
                    offset = tonumber(offset)

                    local mlen = utf.RuneCountInString(word)
                    local mstart = buffer.Loc(offset - 1, linenumber - 1)
                    local mend = buffer.Loc(offset - 1 + mlen, linenumber - 1)
                    if loc:GreaterEqual(mstart) and loc:LessEqual(mend) then
                        local options = ""
                        if buf.Settings["aspell.lang"] ~= "" then
                            options = options .. " --lang="
                                    .. buf.Settings["aspell.lang"]
                        end
                        if buf.Settings["aspell.dict"] ~= "" then
                            options = options .. " --master="
                                    .. buf.Settings["aspell.dict"]
                        end
                        if buf.Settings["aspell.args"] ~= "" then
                            options = options .. " " .. buf.Settings["aspell.args"]
                        end

                        shell.ExecCommand("sh", "-c", "echo '*" .. word
                                .. "\n#\n' | aspell pipe" .. options)
                        spellcheck(micro.CurPane())
                    end
                end
            end
        end
    end
end

function split(inputstr, sep)
    sep=sep or '%s'
    local t={}
    for field,s in string.gmatch(inputstr, "([^"..sep.."]*)("..sep.."?)") do
        table.insert(t,field)
        if s=="" then
            return t
        end
    end
end

-- We need to spellcheck every time, the buffer is modified. Sadly there's
-- no such thing as onBufferModified()

function onBufPaneOpen(bp)
    spellcheck(bp)
end

function onRune(bp)
    spellcheck(bp)
end

function onPastePrimary(bp) -- I'm not sure if this exists
    spellcheck(bp)
end

-- The following were copied from help keybindings

function onCursorUp(bp)
end

function onCursorDown(bp)
end

function onCursorPageUp(bp)
end

function onCursorPageDown(bp)
end

function onCursorLeft(bp)
end

function onCursorRight(bp)
end

function onCursorStart(bp)
end

function onCursorEnd(bp)
end

function onSelectToStart(bp)
end

function onSelectToEnd(bp)
end

function onSelectUp(bp)
end

function onSelectDown(bp)
end

function onSelectLeft(bp)
end

function onSelectRight(bp)
end

function onSelectToStartOfText(bp)
end

function onSelectToStartOfTextToggle(bp)
end

function onWordRight(bp)
end

function onWordLeft(bp)
end

function onSelectWordRight(bp)
end

function onSelectWordLeft(bp)
end

function onMoveLinesUp(bp)
    spellcheck(bp)
end

function onMoveLinesDown(bp)
    spellcheck(bp)
end

function onDeleteWordRight(bp)
    spellcheck(bp)
end

function onDeleteWordLeft(bp)
    spellcheck(bp)
end

function onSelectLine(bp)
end

function onSelectToStartOfLine(bp)
end

function onSelectToEndOfLine(bp)
end

function onInsertNewline(bp)
    spellcheck(bp)
end

function onInsertSpace(bp)
    spellcheck(bp)
end

function onBackspace(bp)
    spellcheck(bp)
end

function onDelete(bp)
    spellcheck(bp)
end

function onCenter(bp)
    -- I dont know what this does
end

function onInsertTab(bp)
    spellcheck(bp)
end

function onSave(bp)
end

function onSaveAll(bp)
end

function onSaveAs(bp)
end

function onFind(bp)
end

function onFindLiteral(bp)
end

function onFindNext(bp)
end

function onFindPrevious(bp)
end

function onUndo(bp)
    spellcheck(bp)
end

function onRedo(bp)
    spellcheck(bp)
end

function onCopy(bp)
end

function onCopyLine(bp)
end

function onCut(bp)
    spellcheck(bp)
end

function onCutLine(bp)
    spellcheck(bp)
end

function onDuplicateLine(bp)
    spellcheck(bp)
end

function onDeleteLine(bp)
    spellcheck(bp)
end

function onIndentSelection(bp)
    spellcheck(bp)
end

function onOutdentSelection(bp)
    spellcheck(bp)
end

function onOutdentLine(bp)
    spellcheck(bp)
end

function onIndentLine(bp)
    spellcheck(bp)
end

function onPaste(bp)
    spellcheck(bp)
end

function onSelectAll(bp)
end

function onOpenFile(bp)
end

function onStart(bp)
end

function onEnd(bp)
end

function onPageUp(bp)
end

function onPageDown(bp)
end

function onSelectPageUp(bp)
end

function onSelectPageDown(bp)
end

function onHalfPageUp(bp)
end

function onHalfPageDown(bp)
end

function onStartOfLine(bp)
end

function onEndOfLine(bp)
end

function onStartOfText(bp)
end

function onStartOfTextToggle(bp)
end

function onParagraphPrevious(bp)
end

function onParagraphNext(bp)
end

function onToggleHelp(bp)
end

function onToggleDiffGutter(bp)
end

function onToggleRuler(bp)
end

function onJumpLine(bp)
end

function onClearStatus(bp)
end

function onShellMode(bp)
end

function onCommandMode(bp)
end

function onQuit(bp)
end

function onQuitAll(bp)
end

function onAddTab(bp)
end

function onPreviousTab(bp)
end

function onNextTab(bp)
end

function onNextSplit(bp)
end

function onUnsplit(bp)
end

function onVSplit(bp)
end

function onHSplit(bp)
end

function onPreviousSplit(bp)
end

function onToggleMacro(bp)
end

function onPlayMacro(bp)
    spellcheck(bp)
end

function onSuspend(bp) -- Unix only
end

function onScrollUp(bp)
end

function onScrollDown(bp)
end

function onSpawnMultiCursor(bp)
end

function onSpawnMultiCursorUp(bp)
end

function onSpawnMultiCursorDown(bp)
end

function onSpawnMultiCursorSelect(bp)
end

function onRemoveMultiCursor(bp)
end

function onRemoveAllMultiCursors(bp)
end

function onSkipMultiCursor(bp)
end

function onNone(bp)
end

function onJumpToMatchingBrace(bp)
end

function onAutocomplete(bp)
    spellcheck(bp)
end

