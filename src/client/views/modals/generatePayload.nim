import strutils, strformat, sequtils, times, os, json
import imguin/[cimgui, glfw_opengl]
import ../widgets/textarea
import ./[configureKillDate, configureWorkingHours]
import ../../utils/appImGui
import ../../utils/globals
import ../../../common/types
import ../../../modules/manager
export addItem

const BUILD_CONFIG_PATH = CONQUEST_ROOT / "data" / "build_config.json"
const IMPERATOR_ROOT = CONQUEST_ROOT / "src" / "imperator"

type
    AgentModalComponent* = ref object of RootObj
        show*: bool
        agentType: int32
        agentTypes: seq[string]
        outputFormat: int32
        outputFormats: seq[string]
        architecture: int32
        architectures: seq[string]
        listener: int32
        sleepDelay: uint32
        jitter: int32
        sleepMask: int32
        spoofStack: bool
        killDateEnabled: bool
        killDate: int64
        workingHoursEnabled: bool
        workingHours: WorkingHours
        verbose: bool
        sleepMaskTechniques: seq[string]
        # Module checkboxes (all enabled by default)
        moduleEnabled: array[9, bool]
        modules: seq[Module]
        buildLog*: TextareaWidget
        killDateModal*: KillDateModalComponent
        workingHoursModal*: WorkingHoursModalComponent
        # Metadata fields
        useCustomIcon: bool
        selectedIconIndex: int32
        customIconPath: array[256, char]
        productName: array[128, char]
        productVersion: array[32, char]
        fileVersion: array[32, char]
        fileDescription: array[256, char]
        companyName: array[128, char]
        copyright: array[128, char]
        originalFilename: array[128, char]
        predefinedIcons: seq[string]
        # Config tab fields (nim.cfg editor)
        monarchNimCfg: string
        imperatorNimCfg: string
        configLoaded: bool

# Forward declarations
proc loadBuildConfig*(component: AgentModalComponent)

proc AgentModal*(): AgentModalComponent =
    result = new AgentModalComponent
    result.show = false
    result.agentType = 0
    result.agentTypes = @["Monarch", "Imperator"]
    result.outputFormat = 0
    result.outputFormats = @["EXE", "DLL"]
    result.architecture = 0
    result.architectures = @["x64", "ARM64"]
    result.listener = 0
    result.sleepDelay = 5
    result.jitter = 15
    result.sleepMask = 0
    result.spoofStack = false
    result.killDateEnabled = false
    result.killDate = 0
    result.workingHoursEnabled = false
    result.workingHours = WorkingHours(
        enabled: false,
        startHour: 0,
        startMinute: 0,
        endHour: 0,
        endMinute: 0
    )
    result.verbose = false

    for technique in SleepObfuscationTechnique.low .. SleepObfuscationTechnique.high:
        result.sleepMaskTechniques.add($technique)

    # Initialize modules with all enabled by default
    result.modules = getModules()
    for i in 0..<result.moduleEnabled.len:
        result.moduleEnabled[i] = true

    result.buildLog = Textarea(showTimestamps = false)
    result.killDateModal = KillDateModal()
    result.workingHoursModal = WorkingHoursModal()

    # Initialize metadata fields
    result.useCustomIcon = false
    result.selectedIconIndex = 0
    result.predefinedIcons = @["None", "Windows", "Folder", "Document", "Setup", "Application"]

    # Initialize config tab fields
    result.monarchNimCfg = newString(16384)
    result.imperatorNimCfg = newString(16384)
    result.configLoaded = false

    # Load saved build config if available
    result.loadBuildConfig()

proc resetModalValues*(component: AgentModalComponent) =
    component.agentType = 0
    component.outputFormat = 0
    component.listener = 0
    component.sleepDelay = 5
    component.jitter = 15
    component.sleepMask = 0
    component.spoofStack = false
    component.killDateEnabled = false
    component.killDate = 0
    component.workingHoursEnabled = false
    component.workingHours = WorkingHours(
        enabled: false,
        startHour: 0,
        startMinute: 0,
        endHour: 0,
        endMinute: 0
    )
    component.verbose = false
    # Reset all modules to enabled
    for i in 0..<component.moduleEnabled.len:
        component.moduleEnabled[i] = true
    component.buildLog.clear()

    # Reset metadata fields
    component.useCustomIcon = false
    component.selectedIconIndex = 0
    for i in 0..<component.customIconPath.len: component.customIconPath[i] = '\0'
    for i in 0..<component.productName.len: component.productName[i] = '\0'
    for i in 0..<component.productVersion.len: component.productVersion[i] = '\0'
    for i in 0..<component.fileVersion.len: component.fileVersion[i] = '\0'
    for i in 0..<component.fileDescription.len: component.fileDescription[i] = '\0'
    for i in 0..<component.companyName.len: component.companyName[i] = '\0'
    for i in 0..<component.copyright.len: component.copyright[i] = '\0'
    for i in 0..<component.originalFilename.len: component.originalFilename[i] = '\0'

    # Reset config tab fields
    component.monarchNimCfg = newString(16384)
    component.imperatorNimCfg = newString(16384)
    component.configLoaded = false

proc loadNimCfgFromDisk*(component: AgentModalComponent, agentType: AgentType) =
    ## Load nim.cfg content from disk into the appropriate string buffer
    let configPath = case agentType:
        of AGENT_IMPERATOR: IMPERATOR_ROOT / "nim.cfg"
        of AGENT_MONARCH: CONQUEST_ROOT / "src" / "agent" / "nim.cfg"

    try:
        if fileExists(configPath):
            let content = readFile(configPath)
            # Create buffer with capacity for editing (content + room to grow)
            let bufferSize = max(16384, content.len + 4096)
            var buffer = newString(bufferSize)
            # Copy content and null-terminate
            for i in 0..<content.len:
                buffer[i] = content[i]
            for i in content.len..<bufferSize:
                buffer[i] = '\0'
            case agentType:
                of AGENT_IMPERATOR: component.imperatorNimCfg = buffer
                of AGENT_MONARCH: component.monarchNimCfg = buffer
    except:
        discard

proc saveBuildConfig*(component: AgentModalComponent) =
    ## Saves the current build configuration to disk
    let config = %*{
        "agentType": component.agentType,
        "outputFormat": component.outputFormat,
        "listener": component.listener,
        "sleepDelay": component.sleepDelay,
        "jitter": component.jitter,
        "sleepMask": component.sleepMask,
        "spoofStack": component.spoofStack,
        "killDateEnabled": component.killDateEnabled,
        "killDate": component.killDate,
        "workingHoursEnabled": component.workingHoursEnabled,
        "workingHours": {
            "enabled": component.workingHours.enabled,
            "startHour": component.workingHours.startHour,
            "startMinute": component.workingHours.startMinute,
            "endHour": component.workingHours.endHour,
            "endMinute": component.workingHours.endMinute
        },
        "verbose": component.verbose,
        "moduleEnabled": component.moduleEnabled.toSeq(),
        # Metadata
        "useCustomIcon": component.useCustomIcon,
        "selectedIconIndex": component.selectedIconIndex,
        "customIconPath": $cast[cstring](addr component.customIconPath[0]),
        "productName": $cast[cstring](addr component.productName[0]),
        "productVersion": $cast[cstring](addr component.productVersion[0]),
        "fileVersion": $cast[cstring](addr component.fileVersion[0]),
        "fileDescription": $cast[cstring](addr component.fileDescription[0]),
        "companyName": $cast[cstring](addr component.companyName[0]),
        "copyright": $cast[cstring](addr component.copyright[0]),
        "originalFilename": $cast[cstring](addr component.originalFilename[0]),
        # Config tab
        "monarchNimCfg": $cstring(component.monarchNimCfg),
        "imperatorNimCfg": $cstring(component.imperatorNimCfg)
    }
    try:
        writeFile(BUILD_CONFIG_PATH, config.pretty())
    except:
        discard

proc loadBuildConfig*(component: AgentModalComponent) =
    ## Loads the saved build configuration from disk
    if not fileExists(BUILD_CONFIG_PATH):
        return
    try:
        let config = parseJson(readFile(BUILD_CONFIG_PATH))

        component.agentType = config{"agentType"}.getInt(0).int32
        component.outputFormat = config{"outputFormat"}.getInt(0).int32
        component.listener = config{"listener"}.getInt(0).int32
        component.sleepDelay = config{"sleepDelay"}.getInt(5).uint32
        component.jitter = config{"jitter"}.getInt(15).int32
        component.sleepMask = config{"sleepMask"}.getInt(0).int32
        component.spoofStack = config{"spoofStack"}.getBool(false)
        component.killDateEnabled = config{"killDateEnabled"}.getBool(false)
        component.killDate = config{"killDate"}.getBiggestInt(0)
        component.workingHoursEnabled = config{"workingHoursEnabled"}.getBool(false)
        component.verbose = config{"verbose"}.getBool(false)

        let wh = config{"workingHours"}
        if wh != nil:
            component.workingHours = WorkingHours(
                enabled: wh{"enabled"}.getBool(false),
                startHour: wh{"startHour"}.getInt(0).int32,
                startMinute: wh{"startMinute"}.getInt(0).int32,
                endHour: wh{"endHour"}.getInt(0).int32,
                endMinute: wh{"endMinute"}.getInt(0).int32
            )

        # Load module enabled states
        let savedModules = config{"moduleEnabled"}
        if savedModules != nil and savedModules.kind == JArray:
            let enabledList = savedModules.getElems()
            for i in 0..<min(enabledList.len, component.moduleEnabled.len):
                component.moduleEnabled[i] = enabledList[i].getBool(true)

        # Load metadata
        component.useCustomIcon = config{"useCustomIcon"}.getBool(false)
        component.selectedIconIndex = config{"selectedIconIndex"}.getInt(0).int32

        # Helper to copy string to char array
        proc copyToArray(arr: var openArray[char], str: string) =
            for i in 0..<arr.len: arr[i] = '\0'
            for i in 0..<min(str.len, arr.len - 1):
                arr[i] = str[i]

        copyToArray(component.customIconPath, config{"customIconPath"}.getStr(""))
        copyToArray(component.productName, config{"productName"}.getStr(""))
        copyToArray(component.productVersion, config{"productVersion"}.getStr(""))
        copyToArray(component.fileVersion, config{"fileVersion"}.getStr(""))
        copyToArray(component.fileDescription, config{"fileDescription"}.getStr(""))
        copyToArray(component.companyName, config{"companyName"}.getStr(""))
        copyToArray(component.copyright, config{"copyright"}.getStr(""))
        copyToArray(component.originalFilename, config{"originalFilename"}.getStr(""))

        # Helper to create a string buffer from content
        proc toBuffer(content: string, minSize: int = 16384): string =
            let bufferSize = max(minSize, content.len + 4096)
            result = newString(bufferSize)
            for i in 0..<content.len:
                result[i] = content[i]
            for i in content.len..<bufferSize:
                result[i] = '\0'

        # Load nim.cfg content - load from saved config or fall back to disk
        let monarchCfg = config{"monarchNimCfg"}.getStr("")
        let imperatorCfg = config{"imperatorNimCfg"}.getStr("")

        # Load monarch config from saved or disk
        if monarchCfg.len > 0:
            component.monarchNimCfg = toBuffer(monarchCfg)
        else:
            component.loadNimCfgFromDisk(AGENT_MONARCH)

        # Load imperator config from saved or disk
        if imperatorCfg.len > 0:
            component.imperatorNimCfg = toBuffer(imperatorCfg)
        else:
            component.loadNimCfgFromDisk(AGENT_IMPERATOR)

        component.configLoaded = true
    except:
        discard

# Helper proc to draw a labeled row with consistent alignment
proc drawLabeledRow(label: cstring, widgetWidth: float32, drawWidget: proc()) =
    igText(label)
    igSameLine(0.0f, igGetStyle().ItemSpacing.x)
    igSetNextItemWidth(widgetWidth)
    drawWidget()

# Tab 1: Basic settings
proc drawBasicTab(component: AgentModalComponent, listeners: seq[UIListener], agentType: AgentType) =
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)
    let inputWidth = availableSize.x * 0.65

    igDummy(vec2(0.0f, 5.0f))

    # Agent type
    igText("Agent type")
    igSetNextItemWidth(-1.0f)
    igCombo_Str("##InputAgentType", addr component.agentType,
                (component.agentTypes.join("\0") & "\0").cstring,
                component.agentTypes.len().int32)

    igDummy(vec2(0.0f, 5.0f))

    # Agent-specific options
    case agentType:
    of AGENT_IMPERATOR:
        # Output format (only for Imperator)
        igText("Output format")
        igSetNextItemWidth(-1.0f)
        igCombo_Str("##InputOutputFormat", addr component.outputFormat,
                    (component.outputFormats.join("\0") & "\0").cstring,
                    component.outputFormats.len().int32)
        igDummy(vec2(0.0f, 5.0f))
        component.architecture = 0  # Imperator is x64 only
    of AGENT_MONARCH:
        component.outputFormat = 0  # Force EXE for Monarch
        # Architecture (only for Monarch)
        igText("Architecture")
        igSetNextItemWidth(-1.0f)
        igCombo_Str("##InputArchitecture", addr component.architecture,
                    (component.architectures.join("\0") & "\0").cstring,
                    component.architectures.len().int32)
        igDummy(vec2(0.0f, 5.0f))

    # Listener
    igText("Listener")
    igSetNextItemWidth(-1.0f)
    igCombo_Str("##InputListener", addr component.listener,
                (listeners.mapIt(it.listenerId).join("\0") & "\0").cstring,
                listeners.len().int32)

    igDummy(vec2(0.0f, 5.0f))

    # Verbose
    igCheckbox("Verbose mode", addr component.verbose)

    # Agent description section
    igDummy(vec2(0.0f, 15.0f))
    igSeparator()
    igDummy(vec2(0.0f, 10.0f))

    igText("Agent Description")
    igDummy(vec2(0.0f, 5.0f))

    case agentType:
    of AGENT_IMPERATOR:
        igTextWrapped("Imperator is a lightweight, position-independent C2 agent written in Nim. It supports x64 Windows targets with EXE and DLL output formats. Imperator features advanced sleep obfuscation techniques (EKKO, ZILEAN, FOLIAGE), stack spoofing, and a minimal footprint suitable for initial access scenarios.")
    of AGENT_MONARCH:
        igTextWrapped("Monarch is a feature-rich C2 agent written in Nim. It supports x64 and ARM64 Windows targets with advanced sleep obfuscation techniques (EKKO, ZILEAN, FOLIAGE), stack spoofing, BOF execution, .NET assembly loading, and comprehensive post-exploitation modules.")

# Tab 2: Sleep settings
proc drawSleepTab(component: AgentModalComponent, agentType: AgentType) =
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)

    igDummy(vec2(0.0f, 5.0f))

    # Sleep delay
    let step: uint32 = 1
    igText("Sleep delay (seconds)")
    igSetNextItemWidth(-1.0f)
    igInputScalar("##InputSleepDelay", ImGuiDataType_U32.int32,
                  addr component.sleepDelay, addr step, nil, "%u",
                  ImGui_InputTextFlags_CharsDecimal.int32)

    igDummy(vec2(0.0f, 5.0f))

    # Jitter
    igText("Jitter")
    igSetNextItemWidth(-1.0f)
    igSliderInt("##InputJitter", addr component.jitter, 0, 100, "%d%%",
                ImGui_SliderFlags_None.int32)

    igDummy(vec2(0.0f, 10.0f))
    igSeparator()
    igDummy(vec2(0.0f, 10.0f))

    # Sleep obfuscation
    igText("Sleep obfuscation")
    igSetNextItemWidth(-1.0f)

    case agentType:
    of AGENT_IMPERATOR:
        # Imperator only supports NONE and EKKO
        let imperatorTechniques = @["NONE", "EKKO"]
        # Clamp to valid range for Imperator
        if component.sleepMask > 1:
            component.sleepMask = 0
        igCombo_Str("##InputSleepMask", addr component.sleepMask,
                    (imperatorTechniques.join("\0") & "\0").cstring,
                    imperatorTechniques.len().int32)
    of AGENT_MONARCH:
        # Monarch supports all techniques
        igCombo_Str("##InputSleepMask", addr component.sleepMask,
                    (component.sleepMaskTechniques.join("\0") & "\0").cstring,
                    component.sleepMaskTechniques.len().int32)

    igDummy(vec2(0.0f, 5.0f))

    # Stack spoofing (only for EKKO/ZILEAN)
    let currentTechnique = component.sleepMaskTechniques[component.sleepMask]
    let stackSpoofDisabled = currentTechnique != $EKKO and currentTechnique != $ZILEAN
    igBeginDisabled(stackSpoofDisabled)
    if stackSpoofDisabled:
        component.spoofStack = false
    igCheckbox("Stack spoofing", addr component.spoofStack)
    igEndDisabled()

    if stackSpoofDisabled:
        igSameLine()
        igTextDisabled("(requires EKKO or ZILEAN)")

# Tab 3: Evasion settings
proc drawEvasionTab(component: AgentModalComponent) =
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)

    igDummy(vec2(0.0f, 5.0f))

    # Kill date
    igText("Kill date")
    igCheckbox("##InputKillDate", addr component.killDateEnabled)
    igSameLine()

    igBeginDisabled(not component.killDateEnabled)
    igSetNextItemWidth(-1.0f)
    let killDateLabel = if component.killDate != 0:
        component.killDate.fromUnix().utc().format("dd. MMMM yyyy HH:mm:ss") & " UTC"
    else:
        "Configure...##KillDate"
    if igButton(killDateLabel.cstring, vec2(-1.0f, 0.0f)):
        igOpenPopup_str("Configure Kill Date", ImGui_PopupFlags_None.int32)
    igEndDisabled()

    let killDate = component.killDateModal.draw()
    if killDate != 0:
        component.killDate = killDate

    igDummy(vec2(0.0f, 10.0f))
    igSeparator()
    igDummy(vec2(0.0f, 10.0f))

    # Working hours
    igText("Working hours")
    igCheckbox("##InputWorkingHours", addr component.workingHoursEnabled)
    igSameLine()

    igBeginDisabled(not component.workingHoursEnabled)
    igSetNextItemWidth(-1.0f)
    let workingHoursLabel = if component.workingHours.enabled:
        fmt"{component.workingHours.startHour:02}:{component.workingHours.startMinute:02} - {component.workingHours.endHour:02}:{component.workingHours.endMinute:02}"
    else:
        "Configure...##WorkingHours"
    if igButton(workingHoursLabel.cstring, vec2(-1.0f, 0.0f)):
        igOpenPopup_str("Configure Working Hours", ImGui_PopupFlags_None.int32)
    igEndDisabled()

    let workingHours = component.workingHoursModal.draw()
    if workingHours.enabled:
        component.workingHours = workingHours

# Tab 4: Module selection (grouped checkboxes)
proc drawModulesTab(component: AgentModalComponent) =
    igDummy(vec2(0.0f, 5.0f))

    # Group: Core
    igText("Core")
    igSeparator()
    igCheckbox("Sleep", addr component.moduleEnabled[0])
    igSameLine(200.0f, 0.0f)
    igCheckbox("Shell", addr component.moduleEnabled[1])

    igDummy(vec2(0.0f, 10.0f))

    # Group: Execution
    igText("Execution")
    igSeparator()
    igCheckbox("BOF", addr component.moduleEnabled[2])
    igSameLine(200.0f, 0.0f)
    igCheckbox("DotNet", addr component.moduleEnabled[3])

    igDummy(vec2(0.0f, 10.0f))

    # Group: Filesystem
    igText("Filesystem")
    igSeparator()
    igCheckbox("Filesystem", addr component.moduleEnabled[4])
    igSameLine(200.0f, 0.0f)
    igCheckbox("File Transfer", addr component.moduleEnabled[5])

    igDummy(vec2(0.0f, 10.0f))

    # Group: Recon
    igText("Recon")
    igSeparator()
    igCheckbox("Screenshot", addr component.moduleEnabled[6])
    igSameLine(200.0f, 0.0f)
    igCheckbox("Situational Awareness", addr component.moduleEnabled[7])

    igDummy(vec2(0.0f, 10.0f))

    # Group: Identity
    igText("Identity")
    igSeparator()
    igCheckbox("Token", addr component.moduleEnabled[8])

# Tab 5: Metadata (Imperator only)
proc drawMetadataTab(component: AgentModalComponent) =
    igDummy(vec2(0.0f, 5.0f))

    # === Icon Section ===
    igText("Icon")
    igSeparator()
    igDummy(vec2(0.0f, 5.0f))

    # Predefined icons dropdown
    igText("Predefined icon")
    igSetNextItemWidth(-1.0f)
    igCombo_Str("##IconSelect", addr component.selectedIconIndex,
                (component.predefinedIcons.join("\0") & "\0").cstring,
                component.predefinedIcons.len().int32)

    igDummy(vec2(0.0f, 5.0f))

    # Custom icon checkbox + path
    igCheckbox("Use custom icon path", addr component.useCustomIcon)
    igBeginDisabled(not component.useCustomIcon)
    igSetNextItemWidth(-1.0f)
    igInputText("##CustomIconPath", addr component.customIconPath[0], 256,
                ImGui_InputTextFlags_None.int32, nil, nil)
    igEndDisabled()

    igDummy(vec2(0.0f, 10.0f))

    # === Version Info Section ===
    igText("Version Information")
    igSeparator()
    igDummy(vec2(0.0f, 5.0f))

    igText("Product name")
    igSetNextItemWidth(-1.0f)
    igInputText("##ProductName", addr component.productName[0], 128,
                ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    igText("File description")
    igSetNextItemWidth(-1.0f)
    igInputText("##FileDescription", addr component.fileDescription[0], 256,
                ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    igText("Company name")
    igSetNextItemWidth(-1.0f)
    igInputText("##CompanyName", addr component.companyName[0], 128,
                ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    igText("Copyright")
    igSetNextItemWidth(-1.0f)
    igInputText("##Copyright", addr component.copyright[0], 128,
                ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    igText("Product version")
    igSetNextItemWidth(-1.0f)
    igInputTextWithHint("##ProductVersion", "1.0.0.0", addr component.productVersion[0], 32,
                        ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    igText("File version")
    igSetNextItemWidth(-1.0f)
    igInputTextWithHint("##FileVersion", "1.0.0.0", addr component.fileVersion[0], 32,
                        ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    igText("Original filename")
    igSetNextItemWidth(-1.0f)
    igInputTextWithHint("##OriginalFilename", "program.exe", addr component.originalFilename[0], 128,
                        ImGui_InputTextFlags_None.int32, nil, nil)

# Tab 6: Config (nim.cfg editor)
proc drawConfigTab(component: AgentModalComponent, agentType: AgentType) =
    igDummy(vec2(0.0f, 5.0f))

    # Determine which config file path to display
    let (configPath, agentLabel) = case agentType:
        of AGENT_IMPERATOR: (IMPERATOR_ROOT / "nim.cfg", "Imperator")
        of AGENT_MONARCH: (CONQUEST_ROOT / "src" / "agent" / "nim.cfg", "Monarch")

    # Display which config is being edited
    igText(fmt"Editing nim.cfg for: {agentLabel}".cstring)
    igTextDisabled(configPath.cstring)

    igDummy(vec2(0.0f, 5.0f))
    igSeparator()
    igDummy(vec2(0.0f, 5.0f))

    # Multi-line text input for nim.cfg content
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)

    # Calculate height: leave room for buttons below
    let textHeight = max(200.0f, availableSize.y - 40.0f)

    # Use unique widget IDs per agent type to prevent ImGui state sharing
    case agentType:
    of AGENT_IMPERATOR:
        igInputTextMultiline("##NimCfgEditorImperator",
                             addr component.imperatorNimCfg[0],
                             component.imperatorNimCfg.len.uint,
                             vec2(-1.0f, textHeight),
                             ImGui_InputTextFlags_None.int32,
                             nil, nil)
    of AGENT_MONARCH:
        igInputTextMultiline("##NimCfgEditorMonarch",
                             addr component.monarchNimCfg[0],
                             component.monarchNimCfg.len.uint,
                             vec2(-1.0f, textHeight),
                             ImGui_InputTextFlags_None.int32,
                             nil, nil)

    igDummy(vec2(0.0f, 5.0f))

    # Reload button to discard changes and reload from disk
    if igButton("Reload from disk", vec2(150.0f, 0.0f)):
        component.loadNimCfgFromDisk(agentType)

    igSameLine()
    igTextDisabled("(Changes are applied on Build)")

# Tab 7: Build (build log and buttons)
proc drawBuildTab(component: AgentModalComponent, listeners: seq[UIListener], agentType: AgentType): AgentBuildInformation =
    igDummy(vec2(0.0f, 5.0f))

    # Build log
    igText("Build log")
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)
    let buildLogHeight = availableSize.y - 50.0f  # Leave room for buttons
    component.buildLog.draw(vec2(-1.0f, buildLogHeight))

    igDummy(vec2(0.0f, 10.0f))

    # Buttons
    igGetContentRegionAvail(addr availableSize)
    let textSpacing = igGetStyle().ItemSpacing.x

    # Check if at least one module is enabled
    var anyModuleEnabled = false
    for enabled in component.moduleEnabled:
        if enabled:
            anyModuleEnabled = true
            break

    igBeginDisabled(not anyModuleEnabled)

    if igButton("Build", vec2(availableSize.x * 0.5 - textSpacing * 0.5, 0.0f)):
        component.buildLog.clear()

        # Calculate modules bitmask from checkboxes
        var modules: uint32 = 0
        for i, enabled in component.moduleEnabled:
            if enabled and i < component.modules.len:
                modules = modules or uint32(component.modules[i].moduleType)

        let nimCfgContent = case agentType:
            of AGENT_IMPERATOR: $cstring(component.imperatorNimCfg)
            of AGENT_MONARCH: $cstring(component.monarchNimCfg)

        result = AgentBuildInformation(
            agentType: agentType,
            outputFormat: cast[OutputFormat](component.outputFormat),
            architecture: cast[Architecture](component.architecture),
            listenerId: listeners[component.listener].listenerId,
            sleepSettings: SleepSettings(
                sleepDelay: component.sleepDelay,
                jitter: cast[uint32](component.jitter),
                sleepTechnique: cast[SleepObfuscationTechnique](component.sleepMask),
                spoofStack: component.spoofStack,
                workingHours: if component.workingHoursEnabled: component.workingHours else: WorkingHours(enabled: false, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0)
            ),
            verbose: component.verbose,
            killDate: if component.killDateEnabled: component.killDate else: 0,
            modules: modules,
            metadata: BinaryMetadata(
                useCustomIcon: component.useCustomIcon,
                iconPath: if component.useCustomIcon:
                            $cast[cstring](addr component.customIconPath[0])
                          else:
                            component.predefinedIcons[component.selectedIconIndex],
                productName: $cast[cstring](addr component.productName[0]),
                productVersion: $cast[cstring](addr component.productVersion[0]),
                fileVersion: $cast[cstring](addr component.fileVersion[0]),
                fileDescription: $cast[cstring](addr component.fileDescription[0]),
                companyName: $cast[cstring](addr component.companyName[0]),
                copyright: $cast[cstring](addr component.copyright[0]),
                originalFilename: $cast[cstring](addr component.originalFilename[0])
            ),
            nimCfgContent: nimCfgContent
        )

        # Save build config when building
        component.saveBuildConfig()

    igEndDisabled()

    igSameLine(0.0f, textSpacing)

    if igButton("Close", vec2(availableSize.x * 0.5 - textSpacing * 0.5, 0.0f)):
        component.resetModalValues()
        igCloseCurrentPopup()

proc draw*(component: AgentModalComponent, listeners: seq[UIListener]): AgentBuildInformation =
    # Center modal
    let vp = igGetMainViewport()
    var center: ImVec2
    ImGuiViewport_GetCenter(addr center, vp)
    igSetNextWindowPos(center, ImGuiCond_Appearing.int32, vec2(0.5f, 0.5f))

    # Fixed window size 700x600
    igSetNextWindowSize(vec2(700.0f, 600.0f), ImGuiCond_Always.int32)

    var show = component.show
    let windowFlags = ImGuiWindowFlags_None.int32
    if igBeginPopupModal("Generate Payload", addr show, windowFlags):
        defer: igEndPopup()

        component.show = show

        var availableSize: ImVec2
        igGetContentRegionAvail(addr availableSize)

        let agentType = cast[AgentType](component.agentType)

        # Load nim.cfg content if not loaded yet
        if not component.configLoaded:
            component.loadNimCfgFromDisk(AGENT_MONARCH)
            component.loadNimCfgFromDisk(AGENT_IMPERATOR)
            component.configLoaded = true

        # Tab bar
        if igBeginTabBar("##PayloadTabs", ImGuiTabBarFlags_None.int32):

            # Tab 1: Basic
            if igBeginTabItem("Basic", nil, ImGuiTabItemFlags_None.int32):
                drawBasicTab(component, listeners, agentType)
                igEndTabItem()

            # Tab 2: Sleep
            if igBeginTabItem("Sleep", nil, ImGuiTabItemFlags_None.int32):
                drawSleepTab(component, agentType)
                igEndTabItem()

            # Tab 3: Evasion
            if igBeginTabItem("Evasion", nil, ImGuiTabItemFlags_None.int32):
                drawEvasionTab(component)
                igEndTabItem()

            # Tab 4: Modules
            if igBeginTabItem("Modules", nil, ImGuiTabItemFlags_None.int32):
                drawModulesTab(component)
                igEndTabItem()

            # Tab 5: Metadata (Imperator only)
            case agentType:
            of AGENT_IMPERATOR:
                if igBeginTabItem("Metadata", nil, ImGuiTabItemFlags_None.int32):
                    drawMetadataTab(component)
                    igEndTabItem()
            of AGENT_MONARCH:
                discard

            # Tab 6: Config (shown for both agent types)
            if igBeginTabItem("Config", nil, ImGuiTabItemFlags_None.int32):
                drawConfigTab(component, agentType)
                igEndTabItem()

            # Tab 7: Build (always last)
            if igBeginTabItem("Build", nil, ImGuiTabItemFlags_None.int32):
                result = drawBuildTab(component, listeners, agentType)
                igEndTabItem()

            igEndTabBar()
