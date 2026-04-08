import os, strutils, sequtils, algorithm
import ../../types/common
import ./globals

type
    CompletionResult* = object
        isFileArg*: bool
        matches*: seq[string]
        baseDir*: string
        prefix*: string
        startPos*: int
        endPos*: int

proc splitPathForCompletion*(partialPath: string): tuple[dir: string, prefix: string] =
    ## Split a partial path into directory and filename prefix
    ## Examples:
    ##   "/home/user/Doc" -> ("/home/user/", "Doc")
    ##   "/home/user/Documents/" -> ("/home/user/Documents/", "")
    ##   "file" -> ("./", "file")
    ##   "" -> ("./", "")
    if partialPath.len == 0:
        return ("./", "")

    # Find last path separator
    var lastSep = -1
    for i in countdown(partialPath.len - 1, 0):
        if partialPath[i] in {'/', '\\'}:
            lastSep = i
            break

    if lastSep == -1:
        # No separator - complete in current directory
        return ("./", partialPath)
    elif lastSep == partialPath.len - 1:
        # Ends with separator - list directory contents
        return (partialPath, "")
    else:
        # Split at last separator
        return (partialPath[0..lastSep], partialPath[lastSep+1..^1])

proc getFileMatches*(baseDir: string, prefix: string): seq[string] =
    ## Get filesystem entries matching the prefix in baseDir
    ## Returns full paths with trailing / for directories
    result = @[]

    let expandedDir = expandTilde(baseDir)

    if not dirExists(expandedDir):
        return @[]

    try:
        for kind, path in walkDir(expandedDir, relative = false):
            let name = extractFilename(path)

            # Match prefix (case-sensitive on Unix)
            let matches = name.startsWith(prefix)

            if matches:
                if kind == pcDir:
                    result.add(path & "/")
                else:
                    result.add(path)
    except OSError:
        discard

    result.sort()

proc getArgumentPosition*(input: string, cursorPos: int): int =
    ## Determine which argument index the cursor is in (0 = command name)
    ## Handles quoted strings properly
    var
        argIndex = 0
        i = 0
        inQuotes = false

    while i < cursorPos and i < input.len:
        let c = input[i]

        if c == '"':
            inQuotes = not inQuotes
        elif c in {' ', '\t'} and not inQuotes:
            # Skip consecutive whitespace
            while i < cursorPos and i < input.len and input[i] in {' ', '\t'}:
                inc i
            if i < cursorPos:
                inc argIndex
            continue

        inc i

    return argIndex

proc extractCurrentArg*(input: string, cursorPos: int): tuple[arg: string, startPos: int, endPos: int] =
    ## Extract the argument the cursor is currently in
    ## Returns the partial argument text and its start/end positions
    var
        startPos = cursorPos
        inQuotes = false

    # Find start of current argument (scan backwards)
    while startPos > 0:
        let c = input[startPos - 1]
        if c == '"':
            inQuotes = not inQuotes
            dec startPos
        elif c in {' ', '\t'} and not inQuotes:
            break
        else:
            dec startPos

    # Skip leading quote if present
    var actualStart = startPos
    if actualStart < input.len and input[actualStart] == '"':
        inc actualStart

    # Extract the partial argument
    let partialArg = if actualStart < cursorPos: input[actualStart..<cursorPos] else: ""

    return (partialArg, startPos, cursorPos)

proc shouldCompleteAsFile*(commandName: string, argIndex: int): bool =
    ## Check if the argument at argIndex for the given command expects a file path
    ## argIndex 0 = command name, argIndex 1 = first argument, etc.
    if argIndex < 1:
        return false

    try:
        let cmd = cq.moduleManager.getCommand(commandName.toLowerAscii())
        let argPos = argIndex - 1  # Convert to 0-based argument index

        if argPos < cmd.arguments.len:
            return cmd.arguments[argPos].argType == FILE
        elif cmd.arguments.len > 0:
            # Check if last argument (for variadic args) is FILE
            return cmd.arguments[^1].argType == FILE
    except ValueError:
        discard

    return false

proc getFileCompletionContext*(input: string, cursorPos: int): CompletionResult =
    ## Main entry point: analyze input and return file completion context
    result.isFileArg = false
    result.matches = @[]

    # Parse to find command name
    let trimmed = input.strip(leading = true, trailing = false)
    if trimmed.len == 0:
        return

    # Extract command name (first word)
    var commandEnd = 0
    while commandEnd < trimmed.len and trimmed[commandEnd] notin {' ', '\t'}:
        inc commandEnd

    let commandName = trimmed[0..<commandEnd]
    let argPos = getArgumentPosition(input, cursorPos)

    # Check if this argument position expects a file
    if not shouldCompleteAsFile(commandName, argPos):
        return

    result.isFileArg = true

    # Extract the current partial path
    let (partialPath, startPos, endPos) = extractCurrentArg(input, cursorPos)
    result.startPos = startPos
    result.endPos = endPos

    # Split into directory and prefix
    let (baseDir, prefix) = splitPathForCompletion(partialPath)
    result.baseDir = baseDir
    result.prefix = prefix

    # Get matching files
    result.matches = getFileMatches(baseDir, prefix)
