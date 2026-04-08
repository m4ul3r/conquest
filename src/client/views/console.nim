import strformat, strutils, sequtils, tables, times, algorithm, os, nimpy
import imguin/[cimgui, glfw_opengl, simple]
import ../utils/[appImGui, globals, utils, fileCompletion]
import ../../types/[common, client]
import ../core/[task, websocket]
import ./widgets/textarea
export addItem

proc Console*(agentId: string): ConsoleComponent =
    result = new ConsoleComponent
    result.agentId = agentId
    result.showConsole = false
    zeroMem(addr result.inputBuffer[0], MAX_INPUT_LENGTH)
    result.textarea = Textarea()
    result.history = @[]
    result.historyPosition = -1
    result.currentInput = ""
    result.filter = ImGuiTextFilter_ImGuiTextFilter("")
    # Initialize file completion state
    result.showFileCompletion = false
    result.fileMatches = @[]
    result.selectedMatchIndex = 0
    result.completionStartPos = 0
    result.completionEndPos = 0
    result.pendingFileSelection = ""

#[
    Text input callback function for managing console history and autocompletion
]#
proc callback(data: ptr ImGuiInputTextCallbackData): cint {.cdecl.} =

    let component = cast[ConsoleComponent](data.UserData)

    case data.EventFlag:
    of ImGui_InputTextFlags_CallbackHistory.int32:
        # Handle command history using arrow-keys

        # Store current input
        if component.historyPosition == -1:
            component.currentInput = $(data.Buf)

        let prev = component.historyPosition

        # Move to a new console history item
        if data.EventKey == ImGuiKey_UpArrow:
            if component.history.len() > 0:
                if component.historyPosition < 0: # We are at the current input and move to the last item in the console history
                    component.historyPosition = component.history.len() - 1
                else:
                    component.historyPosition = max(0, component.historyPosition - 1)

        elif data.EventKey == ImGuiKey_DownArrow:
            if component.historyPosition != -1:
                component.historyPosition = min(component.history.len(), component.historyPosition + 1)

            if component.historyPosition == component.history.len():
                component.historyPosition = -1

        # Update the text buffer if another item was selected
        if prev != component.historyPosition:
            let newText = if component.historyPosition == -1:
                component.currentInput
            else:
                component.history[component.historyPosition]

            # Replace text input
            data.ImGuiInputTextCallbackData_DeleteChars(0, data.BufTextLen)
            data.ImGuiInputTextCallbackData_InsertChars(0, newText.cstring, nil)

            # Set the cursor to the end of the updated input text
            data.CursorPos = newText.len().cint
            data.SelectionStart = newText.len().cint
            data.SelectionEnd = newText.len().cint

        return 0

    of ImGui_InputTextFlags_CallbackCompletion.int32:
        # If popup is already showing, Tab should select the current item
        if component.showFileCompletion and component.fileMatches.len > 0:
            if component.selectedMatchIndex < component.fileMatches.len:
                let match = component.fileMatches[component.selectedMatchIndex]
                let insertText = if ' ' in match: "\"" & match & "\" " else: match & " "
                let replaceLen = component.completionEndPos - component.completionStartPos

                data.ImGuiInputTextCallbackData_DeleteChars(component.completionStartPos.cint, replaceLen.cint)
                data.ImGuiInputTextCallbackData_InsertChars(component.completionStartPos.cint, insertText.cstring, nil)

                component.showFileCompletion = false
                component.fileMatches = @[]
            return 0

        # Get full input and cursor position
        let
            fullInput = $(data.Buf)
            cursorPos = data.CursorPos.int

        # First, try file completion if we're in a file argument
        let fileCtx = getFileCompletionContext(fullInput, cursorPos)

        if fileCtx.isFileArg and fileCtx.matches.len > 0:
            # === FILE COMPLETION ===
            if fileCtx.matches.len == 1:
                # Single match - complete immediately
                let match = fileCtx.matches[0]
                let replaceLen = fileCtx.endPos - fileCtx.startPos

                # Delete current partial path
                data.ImGuiInputTextCallbackData_DeleteChars(fileCtx.startPos.cint, replaceLen.cint)

                # Insert completed path (quote if contains spaces)
                let insertText = if ' ' in match: "\"" & match & "\"" else: match
                data.ImGuiInputTextCallbackData_InsertChars(fileCtx.startPos.cint, insertText.cstring, nil)
            else:
                # Multiple matches - find common prefix and show popup
                var commonPrefix = fileCtx.matches[0]
                for i in 1..<fileCtx.matches.len:
                    var j = 0
                    while j < commonPrefix.len and j < fileCtx.matches[i].len:
                        if commonPrefix[j] != fileCtx.matches[i][j]:
                            break
                        inc j
                    commonPrefix = commonPrefix[0..<j]

                # Complete common prefix if longer than current
                let partialLen = fileCtx.baseDir.len + fileCtx.prefix.len
                if commonPrefix.len > partialLen:
                    let replaceLen = fileCtx.endPos - fileCtx.startPos
                    data.ImGuiInputTextCallbackData_DeleteChars(fileCtx.startPos.cint, replaceLen.cint)
                    let insertText = if ' ' in commonPrefix: "\"" & commonPrefix else: commonPrefix
                    data.ImGuiInputTextCallbackData_InsertChars(fileCtx.startPos.cint, insertText.cstring, nil)

                # Store matches for popup display
                component.showFileCompletion = true
                component.fileMatches = fileCtx.matches
                component.selectedMatchIndex = 0
                component.completionStartPos = fileCtx.startPos
                component.completionEndPos = data.CursorPos.int

            return 0

        # === COMMAND COMPLETION ===
        let commands = cq.moduleManager.getCommands().keys().toSeq() & @["help "]

        # Get the word to complete
        let inputEndPos = data.CursorPos
        var inputStartPos = inputEndPos

        while inputStartPos > 0:
            let c = cast[ptr UncheckedArray[char]](data.Buf)[inputStartPos - 1]
            if c in [' ', '\t', ',', ';']:
                break
            dec inputStartPos

        let inputLen = inputEndPos - inputStartPos
        var currentWord = newString(inputLen)
        for i in 0..<inputLen:
            currentWord[i] = cast[ptr UncheckedArray[char]](data.Buf)[inputStartPos + i]

        # Check for matches
        var matches: seq[string] = @[]
        for cmd in commands:
            if cmd.toLowerAscii().startsWith(currentWord.toLowerAscii()):
                matches.add(cmd)

        # No matching commands found
        if matches.len() == 0:
            return 0

        elif matches.len() == 1:
            data.ImGuiInputTextCallbackData_DeleteChars(inputStartPos.cint, inputLen.cint)
            data.ImGuiInputTextCallbackData_InsertChars(data.CursorPos, matches[0].cstring, nil)

        # More than 1 matching command -> complete common prefix
        else:
            var prefixLen = inputLen

            while prefixLen < matches[0].len():
                let c = matches[0][prefixLen]
                var allMatch = true

                for i in 1 ..< matches.len():
                    if prefixLen >= matches[i].len() or matches[i][prefixLen] != c:
                        allMatch = false
                        break

                if not allMatch:
                    break

                inc prefixLen

            if prefixLen > inputLen:
                data.ImGuiInputTextCallbackData_DeleteChars(inputStartPos.cint, inputLen.cint)
                data.ImGuiInputTextCallbackData_InsertChars(data.CursorPos, matches[0][0..<prefixLen].cstring, nil)

            return 0

    else: discard

#[
    Handling console commands
]#
proc displayHelp(component: ConsoleComponent) =
   for group, commands in cq.moduleManager.groups:
        component.textarea.addItem(LOG_OUTPUT, group.toUpperAscii())
        for cmd in commands.values():
            component.textarea.addItem(LOG_OUTPUT, " * " & cmd.name.alignLeft(25) & cmd.description)
        component.textarea.addItem(LOG_OUTPUT, "")

proc displayCommandHelp(component: ConsoleComponent, command: Command) =
    var usage = command.name & " " & command.arguments.mapIt(
        if it.isFlag and it.argType == BOOL:
            "[" & it.flag & "]"
        elif it.isFlag:
            "[" & it.flag & " " & it.name & "]"
        elif it.isRequired:
            "<" & it.name & ">"
        else:
            "[" & it.name & "]"
    ).join(" ")

    component.textarea.addItem(LOG_OUTPUT, command.description)
    if command.mitre.len() > 0:
        component.textarea.addItem(LOG_OUTPUT, "MITRE ATT&CK: " & command.mitre.join(", "))
    component.textarea.addItem(LOG_OUTPUT, "")
    component.textarea.addItem(LOG_OUTPUT, "Usage: " & usage)
    component.textarea.addItem(LOG_OUTPUT, "Example: " & command.example)
    component.textarea.addItem(LOG_OUTPUT, "")

    var positionalArgs: seq[Argument] = @[]
    var optionalArgs: seq[Argument] = @[]

    for arg in command.arguments:
        if arg.isRequired and not arg.isFlag:
            positionalArgs.add(arg)
        else:
            optionalArgs.add(arg)

    # Display positional arguments
    let widths: seq[int] = @[25, 10]

    if positionalArgs.len > 0:
        component.textarea.addItem(LOG_OUTPUT, "Required arguments:")

        for arg in positionalArgs:
            let argName = arg.name.alignLeft(widths[0])
            let argType = ($arg.argType).toUpperAscii().alignLeft(widths[1])

            # Display multi-line argument description with proper alignment
            let descLines = arg.description.split('\n')
            component.textarea.addItem(LOG_OUTPUT, "  " & argName & " " & argType & " " & descLines[0])
            for i in 1..<descLines.len:
                component.textarea.addItem(LOG_OUTPUT, "  " & ' '.repeat(widths[0]) & " " & ' '.repeat(widths[1]) & " " & descLines[i])

        component.textarea.addItem(LOG_OUTPUT, "")

    # Display optional arguments
    if optionalArgs.len > 0:
        component.textarea.addItem(LOG_OUTPUT, "Optional arguments:")

        for arg in optionalArgs:
            let argName = if arg.isFlag and arg.argType == BOOL:
                arg.flag.alignLeft(widths[0])
            elif arg.isFlag:
                (arg.flag & " " & arg.name).alignLeft(widths[0])
            else:
                arg.name.alignLeft(widths[0])

            let argType = ($arg.argType).toUpperAscii().alignLeft(widths[1])

            # Display multi-line argument description with proper alignment
            let descLines = arg.description.split('\n')
            component.textarea.addItem(LOG_OUTPUT, "  " & argName & " " & argType & " " & descLines[0])
            for i in 1..<descLines.len:
                component.textarea.addItem(LOG_OUTPUT, "  " & ' '.repeat(widths[0]) & " " & ' '.repeat(widths[1]) & " " & descLines[i])

proc handleHelp(component: ConsoleComponent, parsed: seq[string]) =
    try:
        # Try parsing the first argument passed to 'help' as a command
        component.displayCommandHelp(cq.moduleManager.getCommand(parsed[1].toLowerAscii()))
    except IndexDefect:
        # 'help' command is called without additional parameters -> show all available commands
        component.displayHelp()
    except ValueError:
        # Command was not found
        component.textarea.addItem(LOG_ERROR, "The command '" & parsed[1] & "' does not exist.")

    # Add newline at the end of help text
    component.textarea.addItem(LOG_OUTPUT, "")

proc handleAgentCommand*(component: ConsoleComponent, input: string) =
    # Convert user input into sequence of string arguments
    let parsedArgs = parseInput(input)

    # Handle 'help' command
    if parsedArgs[0].toLowerAscii() == "help":
        component.textarea.addItem(LOG_COMMAND, input)
        component.handleHelp(parsedArgs)
        return

    # Handle commands with actions on the agent
    try:
        let command = cq.moduleManager.getCommand(parsedArgs[0].toLowerAscii())

        # If the command has a handler, execute it with the parsed arguments
        if command.hasHandler:
            let args = command.parseArguments(parsedArgs[1..^1])
            discard command.handler.callObject(cq.sessions.agents[component.agentId].agentId, input, args)
        else:
            sendTask(cq.sessions.agents[component.agentId].agentId, input)

    except CatchableError:
        cq.connection.sendLog(component.agentId, component.textarea.addItem(LOG_COMMAND, input))
        cq.connection.sendLog(component.agentId, component.textarea.addItem(LOG_ERROR, getCurrentExceptionMsg()))

proc listProcesses*(component: ConsoleComponent, rootProcesses: seq[uint32], processTable: OrderedTable[uint32, ProcessInfo]) =
    var output = ""

    output.add(component.textarea.addItem(LOG_INFO, "Output: "))

    # Header row
    let headers = @["PID", "PPID", "Process name", "Session", "User context"]
    output.add(component.textarea.addItem(LOG_OUTPUT, headers[0].alignLeft(10) & headers[1].alignLeft(10) & headers[2].alignLeft(80) & headers[3].alignLeft(10) & headers[4]))
    output.add(component.textarea.addItem(LOG_OUTPUT, "-".repeat(len(headers[0])).alignLeft(10) & "-".repeat(len(headers[1])).alignLeft(10) & "-".repeat(len(headers[2])).alignLeft(80) & "-".repeat(len(headers[3])).alignLeft(10) & "-".repeat(len(headers[4]))))

    # Format and print process
    proc printProcess(pid: uint32, indentSpaces: int = 0) =
        if not processTable.contains(pid) or pid == 0:
            return

        var process = processTable[pid]
        let processName = " ".repeat(indentSpaces) & process.name
        let line = ($process.pid).alignLeft(10) & ($process.ppid).alignLeft(10) & processName.alignLeft(80) & ($process.session).alignLeft(10) & process.user
        output.add(component.textarea.addItem(LOG_OUTPUT, line, highlight = int(pid) == cq.sessions.agents[component.agentId].pid))

        # Recursively print child processes with indentation
        for childPid in process.children.sorted():
            printProcess(childPid, indentSpaces + 2)

    for pid in rootProcesses:
        printProcess(pid)

    # Send formatted output to team server for logging
    cq.connection.sendLog(component.agentId, output)

proc listDirectoryContents*(component: ConsoleComponent, path: string, entries: seq[DirectoryEntry]) =
    var
        totalFiles = 0
        totalDirs = 0
        output = ""

    output.add(component.textarea.addItem(LOG_INFO, "Output: "))
    output.add(component.textarea.addItem(LOG_OUTPUT, "Directory: " & path))
    output.add(component.textarea.addItem(LOG_OUTPUT, ""))

    # Table Headers
    let headers = @["Flags", "Last modified", "Size", "Name"]
    output.add(component.textarea.addItem(LOG_OUTPUT, headers[0].alignLeft(8) & headers[1].alignLeft(25) & headers[2].alignLeft(15) & headers[3]))
    output.add(component.textarea.addItem(LOG_OUTPUT,  "-".repeat(headers[0].len).alignLeft(8) & "-".repeat(headers[1].len).alignLeft(25) & "-".repeat(headers[2].len).alignLeft(15) & "-".repeat(headers[3].len)))

    # Process entries
    for entry in entries:
        var mode = ""
        mode &= (if (entry.flags and cast[uint8](IS_DIR)) != 0: (inc totalDirs; "d") else: (inc totalFiles; "-"))
        mode &= (if (entry.flags and cast[uint8](IS_ARCHIVE)) != 0: "a" else: "-")
        mode &= (if (entry.flags and cast[uint8](IS_READONLY)) != 0: "r" else: "-")
        mode &= (if (entry.flags and cast[uint8](IS_HIDDEN)) != 0: "h" else: "-")
        mode &= (if (entry.flags and cast[uint8](IS_SYSTEM)) != 0: "s" else: "-")

        # Date formatting
        let dt = fromUnix(entry.lastWriteTime)
        let dateTimeStr = dt.format("dd/MM/yyyy HH:mm:ss")

        # Size formatting
        let sizeStr = if (entry.flags and cast[uint8](IS_DIR)) != 0: "<DIR>" else: $entry.size

        # Build the entry line using consistent alignment
        output.add(component.textarea.addItem(LOG_OUTPUT, mode.alignLeft(8) & dateTimeStr.alignLeft(25) & sizeStr.alignLeft(15) & entry.name))

    output.add(component.textarea.addItem(LOG_OUTPUT, ""))
    output.add(component.textarea.addItem(LOG_OUTPUT, $totalFiles & " file(s)"))
    output.add(component.textarea.addItem(LOG_OUTPUT, $totalDirs & " dir(s)"))

    # Send formatted output to team server for logging
    cq.connection.sendLog(component.agentId, output)

proc insertFileSelection(component: ConsoleComponent, match: string) =
    ## Insert a selected file path into the input buffer
    let insertText = if ' ' in match: "\"" & match & "\" " else: match & " "

    # Get current buffer as string
    var currentInput = $cast[cstring](addr component.inputBuffer[0])

    # Build new input with replacement
    let before = if component.completionStartPos > 0: currentInput[0..<component.completionStartPos] else: ""
    let after = if component.completionEndPos < currentInput.len: currentInput[component.completionEndPos..^1] else: ""
    let newInput = before & insertText & after

    # Clear and refill buffer
    zeroMem(addr component.inputBuffer[0], MAX_INPUT_LENGTH)
    if newInput.len > 0:
        copyMem(addr component.inputBuffer[0], newInput.cstring, min(newInput.len, MAX_INPUT_LENGTH - 1))

    component.showFileCompletion = false
    component.fileMatches = @[]

proc drawFileCompletionPopup(component: ConsoleComponent, availWidth: float32) =
    ## Draw the file completion dropdown when multiple matches exist
    if not component.showFileCompletion or component.fileMatches.len == 0:
        return

    # Calculate size
    let maxVisibleItems = min(component.fileMatches.len, 8)
    let itemHeight = igGetTextLineHeightWithSpacing()
    let popupHeight = itemHeight * maxVisibleItems.float32 + igGetStyle().WindowPadding.y * 2

    # Draw as a child window (renders inline in current window)
    let childFlags = ImGuiWindowFlags_NoTitleBar.int32 or
                     ImGuiWindowFlags_NoResize.int32 or
                     ImGuiWindowFlags_NoMove.int32 or
                     ImGuiWindowFlags_HorizontalScrollbar.int32

    igPushStyleColor_Vec4(ImGuiCol_ChildBg.int32, vec4(0.15f, 0.15f, 0.15f, 0.95f))
    igPushStyleVar_Vec2(ImGuiStyleVar_WindowPadding.int32, vec2(8, 4))

    if igBeginChild_Str("##FileCompletionList", vec2(availWidth, popupHeight), ImGuiChildFlags_Borders.int32, childFlags):
        for i, match in component.fileMatches:
            let isSelected = i == component.selectedMatchIndex
            let displayName = extractFilename(match.strip(chars = {'/'}))
            let isDir = match.endsWith("/")
            let label = if isDir: displayName & "/" else: displayName

            if igSelectable_Bool(label.cstring, isSelected, 0, vec2(0, 0)):
                # User clicked on this item - insert it
                component.insertFileSelection(match)

            # Show full path as tooltip
            if igIsItemHovered(ImGuiHoveredFlags_None.int32):
                igSetTooltip(match.cstring)

            # Keep selected item in view
            if isSelected:
                igSetScrollHereY(0.5f)

    igEndChild()
    igPopStyleVar(1)
    igPopStyleColor(1)

proc draw*(component: ConsoleComponent) =
    if not cq.sessions.agents.hasKey(component.agentId): return

    let agent = cq.sessions.agents[component.agentId]

    igBegin(agent.consoleTitle.cstring, addr component.showConsole, 0)
    defer: igEnd()

    let io = igGetIO()

    var focusInput = false

    #[
        Console items/text section using ImGuiTextSelect in a child window
        Features:
            - Horizontal+vertical scrolling,
            - Autoscroll
            - Colored text output
            - Text highlighting, copy/paste

        Problems I encountered with other approaches (Multi-line Text Input, TextEditor, ...):
            - https://github.com/ocornut/imgui/issues/383#issuecomment-2080346129
            - https://github.com/ocornut/imgui/issues/950
    ]#
    let consolePadding: float = 10.0f
    let textSpacing = igGetStyle().ItemSpacing.x

    # Calculate footer height, including popup if visible
    var footerHeight = (consolePadding * 2) + (igGetStyle().ItemSpacing.y + igGetFrameHeightWithSpacing()) * 0.75f
    if component.showFileCompletion and component.fileMatches.len > 0:
        let maxVisibleItems = min(component.fileMatches.len, 8)
        let itemHeight = igGetTextLineHeightWithSpacing()
        let popupHeight = itemHeight * maxVisibleItems.float32 + igGetStyle().WindowPadding.y * 2
        footerHeight += popupHeight + igGetStyle().ItemSpacing.y

    # Padding
    igDummy(vec2(0.0f, consolePadding))


    #[
        Session information
    ]#
    let domain = if agent.domain.isEmptyOrWhitespace(): "" else: fmt".{agent.domain}"
    let sessionInfo = fmt"{agent.username}@{agent.hostname}{domain} | {agent.ipInternal} | {$agent.pid}/{agent.process}".cstring
    igTextColored(GRAY, sessionInfo)
    igSameLine(0.0f, 0.0f)

    #[
        Filter & Options
    ]#
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)
    var labelSize: ImVec2
    igCalcTextSize(addr labelSize, ICON_FA_MAGNIFYING_GLASS, nil, false, 0.0f)

    let searchBoxWidth: float32 = 400.0f
    igSameLine(0.0f, availableSize.x  - (labelSize.x + textSpacing) - searchBoxWidth)

    # Show tooltip when hovering the search icon
    igTextUnformatted(ICON_FA_MAGNIFYING_GLASS.cstring, nil)
    if igIsItemHovered(ImGuiHoveredFlags_None.int32):
        igBeginTooltip()
        igText("Press CTRL+F to focus console filter.")
        igText("Use \",\" as a delimiter to filter for multiple values.")
        igText("Use \"-\" to exclude values.")
        igText("Example: \"-warning,a,b\" returns all lines that do not include \"warning\" but include either \"a\" or \"b\".")
        igEndTooltip()

    if igIsWindowFocused(ImGui_FocusedFlags_ChildWindows.int32) and io.KeyCtrl and igIsKeyPressed_Bool(ImGuiKey_F, false):
        igSetKeyboardFocusHere(0)

    igSameLine(0.0f, textSpacing)
    component.filter.ImGuiTextFilter_Draw("##ConsoleSearch", searchBoxWidth)

    #[
        Console textarea
    ]#
    component.textarea.draw(vec2(-1.0f, -footerHeight), component.filter)

    # Padding
    igDummy(vec2(0.0f, consolePadding))

    #[
        File completion popup (drawn above input field)
    ]#
    igGetContentRegionAvail(addr availableSize)
    component.drawFileCompletionPopup(availableSize.x)

    #[
        Input field with prompt indicator
    ]#
    igText(fmt"[{agent.agentId}]".cstring)
    igSameLine(0.0f, textSpacing)

    # Calculate available width for input
    igGetContentRegionAvail(addr availableSize)
    igSetNextItemWidth(availableSize.x)

    let inputFlags = ImGuiInputTextFlags_EnterReturnsTrue.int32 or ImGuiInputTextFlags_EscapeClearsAll.int32 or ImGuiInputTextFlags_CallbackHistory.int32 or ImGuiInputTextFlags_CallbackCompletion.int32
    if igInputText("##Input", cast[cstring](addr component.inputBuffer[0]), MAX_INPUT_LENGTH, inputFlags, callback, cast[pointer](component)):
        # Close file completion popup on enter
        component.showFileCompletion = false
        component.fileMatches = @[]

        let command = ($cast[cstring]((addr component.inputBuffer[0]))).strip()
        if not command.isEmptyOrWhitespace():
            # Send command to team server
            component.handleAgentCommand(command)

            # Add command to console history
            component.history.add(command)
            component.historyPosition = -1

        zeroMem(addr component.inputBuffer[0], MAX_INPUT_LENGTH)
        focusInput = true

    # Handle keyboard navigation for file completion popup
    # Note: Don't handle Tab here as it conflicts with the completion callback
    if component.showFileCompletion and component.fileMatches.len > 0:
        if igIsKeyPressed_Bool(ImGuiKey_DownArrow, true):
            component.selectedMatchIndex = min(component.selectedMatchIndex + 1, component.fileMatches.len - 1)
        elif igIsKeyPressed_Bool(ImGuiKey_UpArrow, true):
            component.selectedMatchIndex = max(component.selectedMatchIndex - 1, 0)
        elif igIsKeyPressed_Bool(ImGuiKey_Escape, false):
            component.showFileCompletion = false
            component.fileMatches = @[]
        elif igIsKeyPressed_Bool(ImGuiKey_Enter, false):
            if component.selectedMatchIndex < component.fileMatches.len:
                component.insertFileSelection(component.fileMatches[component.selectedMatchIndex])
                focusInput = true

    igSetItemDefaultFocus()
    if focusInput:
        igSetKeyboardFocusHere(-1)
