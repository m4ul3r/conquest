import strformat, strutils, sequtils, os
import imguin/[cimgui, glfw_opengl, simple]
import ../utils/[appImGui, colors, fileCompletion]
import ../../common/[types, utils]
import ../../modules/manager
import ../core/[task, websocket]
import ./widgets/textarea
export addItem

const MAX_INPUT_LENGTH = 4096 # Input needs to allow enough characters for long commands (e.g. Rubeus tickets)
type
    ConsoleComponent* = ref object of RootObj
        agent*: UIAgent
        showConsole*: bool
        inputBuffer: array[MAX_INPUT_LENGTH, char]
        console*: TextareaWidget
        history: seq[string]
        historyPosition: int
        currentInput: string
        filter: ptr ImGuiTextFilter
        # File completion state
        showFileCompletion*: bool
        fileMatches*: seq[string]
        selectedMatchIndex*: int
        completionStartPos*: int
        completionEndPos*: int
        pendingFileSelection*: string

proc Console*(agent: UIAgent): ConsoleComponent =
    result = new ConsoleComponent
    result.agent = agent
    result.showConsole = true
    zeroMem(addr result.inputBuffer[0], MAX_INPUT_LENGTH)
    result.console = Textarea()
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
                let currentLen = fileCtx.endPos - fileCtx.startPos
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

        # === COMMAND COMPLETION (existing logic) ===
        let commands = getCommands(component.agent.modules).mapIt(it.name & " ") & @["help "]

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
    for cmd in getCommands(component.agent.modules):
        component.console.addItem(LOG_OUTPUT, " * " & cmd.name.alignLeft(25) & cmd.description)

proc displayCommandHelp(component: ConsoleComponent, command: Command) =
    var usage = command.name & " " & command.arguments.mapIt(
        if it.isRequired: "<" & it.name & ">" else: "[" & it.name & "]"
    ).join(" ")
    
    component.console.addItem(LOG_OUTPUT, command.description)
    component.console.addItem(LOG_OUTPUT, "Usage    : " & usage)    
    component.console.addItem(LOG_OUTPUT, "Example  : " & command.example)
    component.console.addItem(LOG_OUTPUT, "")

    if command.arguments.len > 0:
        component.console.addItem(LOG_OUTPUT, "Arguments:")
        
        let header = @["Name", "Type", "Required", "Description"]
        component.console.addItem(LOG_OUTPUT, "   " & header[0].alignLeft(15) & " " & header[1].alignLeft(6) & " " & header[2].alignLeft(8) & " " & header[3])
        component.console.addItem(LOG_OUTPUT, "   " & '-'.repeat(15) & " " & '-'.repeat(6) & " " & '-'.repeat(8) & " " & '-'.repeat(20))
        
        for arg in command.arguments:
            let isRequired = if arg.isRequired: "YES" else: "NO"
            component.console.addItem(LOG_OUTPUT, " * " & arg.name.alignLeft(15) & " " & ($arg.argumentType).toUpperAscii().alignLeft(6) & " " & isRequired.align(8) & " " & arg.description)

proc handleHelp(component: ConsoleComponent, parsed: seq[string]) =
    try:
        # Try parsing the first argument passed to 'help' as a command
        component.displayCommandHelp(getCommandByName(parsed[1]))
    except IndexDefect:
        # 'help' command is called without additional parameters
        component.displayHelp()
    except ValueError:
        # Command was not found
        component.console.addItem(LOG_ERROR, "The command '" & parsed[1] & "' does not exist.")

    # Add newline at the end of help text
    component.console.addItem(LOG_OUTPUT, "")

proc handleAgentCommand*(component: ConsoleComponent, connection: WsConnection, input: string) =
    # Add command to console
    component.console.addItem(LOG_COMMAND, input)

    # Convert user input into sequence of string arguments
    let parsedArgs = parseInput(input)
    
    # Handle 'help' command
    if parsedArgs[0] == "help":
        component.handleHelp(parsedArgs)
        return
        
    # Handle commands with actions on the agent
    try:
        let 
            command = getCommandByName(parsedArgs[0])
            task = createTask(component.agent.agentId, component.agent.listenerId, command, parsedArgs[1..^1])

        connection.sendAgentTask(component.agent.agentId, input, task)
        component.console.addItem(LOG_INFO, "Tasked agent to " & command.description.toLowerAscii() & " (" & Uuid.toString(task.taskId) & ")")

    except CatchableError:
        component.console.addItem(LOG_ERROR, getCurrentExceptionMsg())

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

proc draw*(component: ConsoleComponent, connection: WsConnection) =
    igBegin(fmt"[{component.agent.agentId}] {component.agent.username}@{component.agent.hostname}".cstring, addr component.showConsole, 0)
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
    let domain = if component.agent.domain.isEmptyOrWhitespace(): "" else: fmt".{component.agent.domain}"
    let sessionInfo = fmt"{component.agent.username}@{component.agent.hostname}{domain} | {component.agent.ipInternal} | {$component.agent.pid}/{component.agent.process}".cstring
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
    component.console.draw(vec2(-1.0f, -footerHeight), component.filter)
    
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
    igText(fmt"[{component.agent.agentId}]".cstring)
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
            component.handleAgentCommand(connection, command)

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