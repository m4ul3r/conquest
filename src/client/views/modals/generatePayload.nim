import strutils, strformat, sequtils, tables, times, algorithm, json, os
import imguin/[cimgui, glfw_opengl]
import ../widgets/[dualListSelection, textarea]
import ./[configureKillDate, configureWorkingHours]
import ../../utils/[appImGui, globals]
import ../../../types/[common, client, event]
export addItem

const BUILD_CONFIG_PATH* = CONQUEST_ROOT / "data" / "build_config.json"
const IMPERATOR_ROOT_CLIENT = CONQUEST_ROOT / "src" / "imperator"
const MONARCH_NIM_CFG = CONQUEST_ROOT / "src" / "agents" / "monarch" / "nim.cfg"

proc `$`(payloadType: PayloadType): string =
    case payloadType:
    of EXE: "Windows Executable (.exe)"
    of SVC: "Windows Service Executable (.svc.exe)"
    of DLL: "Windows DLL (.dll)"

# ---------------------------------------------------------------------------
# nim.cfg load/save helpers
# ---------------------------------------------------------------------------

proc filterDynamicDefines(content: string): string =
    var lines: seq[string]
    for line in content.splitLines():
        if line.startsWith("-d:CONFIGURATION") or
           line.startsWith("-d:malDebug") or
           line.startsWith("-d:dll"):
            continue
        if line.contains("Encrypted configuration placeholder") or
           line.contains("Dynamic build configuration"):
            continue
        lines.add(line)
    return lines.join("\n")

proc loadNimCfgFromDisk*(component: AgentModalComponent, agentType: AgentType) =
    let configPath = case agentType:
        of AGENT_IMPERATOR: IMPERATOR_ROOT_CLIENT / "nim.cfg"
        of AGENT_MONARCH: MONARCH_NIM_CFG
    try:
        if fileExists(configPath):
            let raw = filterDynamicDefines(readFile(configPath))
            let bufSize = max(16384, raw.len + 4096)
            var buf = newString(bufSize)
            for i in 0..<raw.len: buf[i] = raw[i]
            for i in raw.len..<bufSize: buf[i] = '\0'
            case agentType:
            of AGENT_IMPERATOR: component.imperatorNimCfg = buf
            of AGENT_MONARCH:   component.monarchNimCfg   = buf
    except: discard

proc saveNimCfgToDisk*(component: AgentModalComponent, agentType: AgentType) =
    let configPath = case agentType:
        of AGENT_IMPERATOR: IMPERATOR_ROOT_CLIENT / "nim.cfg"
        of AGENT_MONARCH: MONARCH_NIM_CFG
    try:
        let buf = case agentType:
            of AGENT_IMPERATOR: component.imperatorNimCfg
            of AGENT_MONARCH:   component.monarchNimCfg
        var contentLen = 0
        for i in 0..<buf.len:
            if buf[i] == '\0': contentLen = i; break
        writeFile(configPath, filterDynamicDefines(buf[0..<contentLen]))
    except: discard

# ---------------------------------------------------------------------------
# Build config persistence
# ---------------------------------------------------------------------------

proc saveBuildConfig*(component: AgentModalComponent) =
    try:
        let config = %*{
            "agentType": component.agentType,
            "architecture": component.architecture,
            "payloadType": component.payloadType,
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
            "monarchNimCfg": $cstring(component.monarchNimCfg),
            "imperatorNimCfg": $cstring(component.imperatorNimCfg)
        }
        writeFile(BUILD_CONFIG_PATH, config.pretty())
    except: discard

proc loadBuildConfig*(component: AgentModalComponent) =
    if not fileExists(BUILD_CONFIG_PATH): return
    try:
        let config = parseJson(readFile(BUILD_CONFIG_PATH))

        component.agentType    = config{"agentType"}.getInt(0).int32
        component.architecture = config{"architecture"}.getInt(0).int32
        component.payloadType  = config{"payloadType"}.getInt(0).int32
        component.listener     = config{"listener"}.getInt(0).int32
        component.sleepDelay   = config{"sleepDelay"}.getInt(5).uint32
        component.jitter       = config{"jitter"}.getInt(15).int32
        component.sleepMask    = config{"sleepMask"}.getInt(0).int32
        component.spoofStack   = config{"spoofStack"}.getBool(false)
        component.killDateEnabled     = config{"killDateEnabled"}.getBool(false)
        component.killDate     = config{"killDate"}.getBiggestInt(0)
        component.workingHoursEnabled = config{"workingHoursEnabled"}.getBool(false)
        component.verbose      = config{"verbose"}.getBool(false)

        let wh = config{"workingHours"}
        if wh != nil:
            component.workingHours = WorkingHours(
                enabled: wh{"enabled"}.getBool(false),
                startHour: wh{"startHour"}.getInt(0).int32,
                startMinute: wh{"startMinute"}.getInt(0).int32,
                endHour: wh{"endHour"}.getInt(0).int32,
                endMinute: wh{"endMinute"}.getInt(0).int32
            )

        component.useCustomIcon    = config{"useCustomIcon"}.getBool(false)
        component.selectedIconIndex = config{"selectedIconIndex"}.getInt(0).int32

        proc copyToArray(arr: var openArray[char], s: string) =
            for i in 0..<arr.len: arr[i] = '\0'
            for i in 0..<min(s.len, arr.len - 1): arr[i] = s[i]

        copyToArray(component.customIconPath,  config{"customIconPath"}.getStr(""))
        copyToArray(component.productName,     config{"productName"}.getStr(""))
        copyToArray(component.productVersion,  config{"productVersion"}.getStr(""))
        copyToArray(component.fileVersion,     config{"fileVersion"}.getStr(""))
        copyToArray(component.fileDescription, config{"fileDescription"}.getStr(""))
        copyToArray(component.companyName,     config{"companyName"}.getStr(""))
        copyToArray(component.copyright,       config{"copyright"}.getStr(""))
        copyToArray(component.originalFilename, config{"originalFilename"}.getStr(""))

        proc toBuffer(content: string, minSize: int = 16384): string =
            let sz = max(minSize, content.len + 4096)
            result = newString(sz)
            for i in 0..<content.len: result[i] = content[i]
            for i in content.len..<sz: result[i] = '\0'

        let monarchCfg   = config{"monarchNimCfg"}.getStr("")
        let imperatorCfg = config{"imperatorNimCfg"}.getStr("")

        if monarchCfg.len > 0:   component.monarchNimCfg   = toBuffer(monarchCfg)
        else:                     component.loadNimCfgFromDisk(AGENT_MONARCH)

        if imperatorCfg.len > 0: component.imperatorNimCfg = toBuffer(imperatorCfg)
        else:                     component.loadNimCfgFromDisk(AGENT_IMPERATOR)

        component.configLoaded = true
    except: discard

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

proc AgentModal*(): AgentModalComponent =
    result = new AgentModalComponent
    result.show = false
    result.agentType = 0
    result.agentTypes = @["Monarch", "Imperator"]
    result.architecture = 0
    result.architectures = @["x64", "ARM64"]
    result.listener = 0
    result.payloadType = 0
    result.sleepDelay = 5
    result.jitter = 15
    result.sleepMask = 0
    result.spoofStack = false
    result.killDateEnabled = false
    result.killDate = 0
    result.workingHoursEnabled = false
    result.workingHours = WorkingHours(
        enabled: false, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0
    )
    result.verbose = false

    for payloadType in PayloadType.low .. PayloadType.high:
        result.payloadTypes.add($payloadType)

    for technique in SleepObfuscationTechnique.low .. SleepObfuscationTechnique.high:
        result.sleepMaskTechniques.add($technique)

    proc compareModules(x, y: Module): int = cmp(x.name, y.name)
    proc moduleName(module: Module): string = module.name
    proc moduleDesc(module: Module): string =
        result = module.description & "\nModule commands:\n"
        for cmd in module.commands: result &= " - " & cmd.name & "\n"

    result.moduleSelection = DualListSelection(
        cq.moduleManager.modules.values.toSeq().sorted(compareModules),
        moduleName, compareModules, moduleDesc
    )
    result.buildLog         = Textarea(showTimestamps = false)
    result.killDateModal    = KillDateModal()
    result.workingHoursModal = WorkingHoursModal()

    result.useCustomIcon    = false
    result.selectedIconIndex = 0
    result.predefinedIcons  = @["None", "Windows", "Folder", "Document", "Setup", "Application"]

    result.monarchNimCfg   = newString(16384)
    result.imperatorNimCfg = newString(16384)
    result.configLoaded    = false

    result.loadBuildConfig()

proc resetModalValues*(component: AgentModalComponent) =
    component.agentType    = 0
    component.architecture = 0
    component.payloadType  = 0
    component.listener     = 0
    component.sleepDelay   = 5
    component.jitter       = 15
    component.sleepMask    = 0
    component.spoofStack   = false
    component.killDateEnabled = false
    component.killDate     = 0
    component.workingHoursEnabled = false
    component.workingHours = WorkingHours(
        enabled: false, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0
    )
    component.verbose = false
    component.moduleSelection.reset()
    component.buildLog.clear()
    component.useCustomIcon    = false
    component.selectedIconIndex = 0
    for i in 0..<component.customIconPath.len:  component.customIconPath[i]  = '\0'
    for i in 0..<component.productName.len:     component.productName[i]     = '\0'
    for i in 0..<component.productVersion.len:  component.productVersion[i]  = '\0'
    for i in 0..<component.fileVersion.len:     component.fileVersion[i]     = '\0'
    for i in 0..<component.fileDescription.len: component.fileDescription[i] = '\0'
    for i in 0..<component.companyName.len:     component.companyName[i]     = '\0'
    for i in 0..<component.copyright.len:       component.copyright[i]       = '\0'
    for i in 0..<component.originalFilename.len: component.originalFilename[i] = '\0'
    component.monarchNimCfg   = newString(16384)
    component.imperatorNimCfg = newString(16384)
    component.configLoaded    = false

# ---------------------------------------------------------------------------
# Tab drawing helpers
# ---------------------------------------------------------------------------

proc drawBasicTab(component: AgentModalComponent, listeners: seq[UIListener], agentType: AgentType) =
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)

    igDummy(vec2(0.0f, 5.0f))

    igText("Agent type")
    igSetNextItemWidth(-1.0f)
    igCombo_Str("##InputAgentType", addr component.agentType,
                (component.agentTypes.join("\0") & "\0").cstring,
                component.agentTypes.len().int32)

    igDummy(vec2(0.0f, 5.0f))

    case agentType:
    of AGENT_IMPERATOR:
        igText("Payload type")
        igSetNextItemWidth(-1.0f)
        igCombo_Str("##InputPayloadType", addr component.payloadType,
                    (component.payloadTypes.join("\0") & "\0").cstring,
                    component.payloadTypes.len().int32)
        igDummy(vec2(0.0f, 5.0f))
        igText("Architecture")
        igSetNextItemWidth(-1.0f)
        igCombo_Str("##InputArchitecture", addr component.architecture,
                    (component.architectures.join("\0") & "\0").cstring,
                    component.architectures.len().int32)
        igDummy(vec2(0.0f, 5.0f))
    of AGENT_MONARCH:
        component.payloadType = 0  # Monarch always EXE by default
        igText("Architecture")
        igSetNextItemWidth(-1.0f)
        igCombo_Str("##InputArchitecture", addr component.architecture,
                    (component.architectures.join("\0") & "\0").cstring,
                    component.architectures.len().int32)
        igDummy(vec2(0.0f, 5.0f))

    igText("Listener")
    igSetNextItemWidth(-1.0f)
    igCombo_Str("##InputListener", addr component.listener,
                (listeners.mapIt(it.listenerId & " (" & $it.listenerType & ")").join("\0") & "\0").cstring,
                listeners.len().int32)

    igDummy(vec2(0.0f, 5.0f))
    igCheckbox("Verbose mode", addr component.verbose)

    igDummy(vec2(0.0f, 15.0f))
    igSeparator()
    igDummy(vec2(0.0f, 10.0f))

    igText("Agent description")
    igDummy(vec2(0.0f, 5.0f))
    case agentType:
    of AGENT_IMPERATOR:
        igTextWrapped("Imperator is a lightweight, position-independent C2 agent written in Nim. It supports x64 and ARM64 Windows targets with EXE and DLL output formats. Both architectures support advanced sleep obfuscation techniques (EKKO, ZILEAN, FOLIAGE) with stack spoofing.")
    of AGENT_MONARCH:
        igTextWrapped("Monarch is a feature-rich C2 agent written in Nim. It supports x64 and ARM64 Windows targets with advanced sleep obfuscation techniques (EKKO, ZILEAN, FOLIAGE), stack spoofing, BOF execution, .NET assembly loading, and comprehensive post-exploitation modules.")

proc drawSleepTab(component: AgentModalComponent, agentType: AgentType) =
    igDummy(vec2(0.0f, 5.0f))

    let step: uint32 = 1
    igText("Sleep delay (seconds)")
    igSetNextItemWidth(-1.0f)
    igInputScalar("##InputSleepDelay", ImGuiDataType_U32.int32,
                  addr component.sleepDelay, addr step, nil, "%u",
                  ImGui_InputTextFlags_CharsDecimal.int32)

    igDummy(vec2(0.0f, 5.0f))
    igText("Jitter")
    igSetNextItemWidth(-1.0f)
    igSliderInt("##InputJitter", addr component.jitter, 0, 100, "%d%%",
                ImGui_SliderFlags_None.int32)

    igDummy(vec2(0.0f, 10.0f))
    igSeparator()
    igDummy(vec2(0.0f, 10.0f))

    igText("Sleep obfuscation")
    igSetNextItemWidth(-1.0f)

    let isArm64 = component.architecture == 1

    case agentType:
    of AGENT_IMPERATOR:
        if isArm64:
            igCombo_Str("##InputSleepMask", addr component.sleepMask,
                        (component.sleepMaskTechniques.join("\0") & "\0").cstring,
                        component.sleepMaskTechniques.len().int32)
        else:
            let imperatorTechniques = @["NONE", "EKKO"]
            if component.sleepMask > 1: component.sleepMask = 0
            igCombo_Str("##InputSleepMask", addr component.sleepMask,
                        (imperatorTechniques.join("\0") & "\0").cstring,
                        imperatorTechniques.len().int32)
    of AGENT_MONARCH:
        igCombo_Str("##InputSleepMask", addr component.sleepMask,
                    (component.sleepMaskTechniques.join("\0") & "\0").cstring,
                    component.sleepMaskTechniques.len().int32)

    igDummy(vec2(0.0f, 5.0f))

    let currentTechnique = component.sleepMaskTechniques[component.sleepMask]
    let stackSpoofDisabled = currentTechnique != $EKKO and currentTechnique != $ZILEAN
    igBeginDisabled(stackSpoofDisabled)
    if stackSpoofDisabled: component.spoofStack = false
    igCheckbox("Stack spoofing", addr component.spoofStack)
    igEndDisabled()
    if stackSpoofDisabled:
        igSameLine()
        igTextDisabled("(requires EKKO or ZILEAN)")

proc drawEvasionTab(component: AgentModalComponent) =
    igDummy(vec2(0.0f, 5.0f))

    igText("Kill date")
    igCheckbox("##InputKillDate", addr component.killDateEnabled)
    igSameLine()

    igBeginDisabled(not component.killDateEnabled)
    igSetNextItemWidth(-1.0f)
    let killDateLabel = if component.killDate != 0:
        component.killDate.fromUnix().utc().format("dd. MMMM yyyy HH:mm:ss") & " UTC"
    else: "Configure...##KillDate"
    if igButton(killDateLabel.cstring, vec2(-1.0f, 0.0f)):
        igOpenPopup_str("Configure Kill Date", ImGui_PopupFlags_None.int32)
    igEndDisabled()

    let killDate = component.killDateModal.draw()
    if killDate != 0: component.killDate = killDate

    igDummy(vec2(0.0f, 10.0f))
    igSeparator()
    igDummy(vec2(0.0f, 10.0f))

    igText("Working hours")
    igCheckbox("##InputWorkingHours", addr component.workingHoursEnabled)
    igSameLine()

    igBeginDisabled(not component.workingHoursEnabled)
    igSetNextItemWidth(-1.0f)
    let workingHoursLabel = if component.workingHours.enabled:
        fmt"{component.workingHours.startHour:02}:{component.workingHours.startMinute:02} - {component.workingHours.endHour:02}:{component.workingHours.endMinute:02}"
    else: "Configure...##WorkingHours"
    if igButton(workingHoursLabel.cstring, vec2(-1.0f, 0.0f)):
        igOpenPopup_str("Configure Working Hours", ImGui_PopupFlags_None.int32)
    igEndDisabled()

    let workingHours = component.workingHoursModal.draw()
    if workingHours.enabled: component.workingHours = workingHours

proc drawModulesTab(component: AgentModalComponent) =
    igDummy(vec2(0.0f, 5.0f))
    igText("Modules:")
    component.moduleSelection.draw()

proc drawMetadataTab(component: AgentModalComponent) =
    igDummy(vec2(0.0f, 5.0f))
    igText("Icon")
    igSeparator()
    igDummy(vec2(0.0f, 5.0f))

    igText("Predefined icon")
    igSetNextItemWidth(-1.0f)
    igCombo_Str("##IconSelect", addr component.selectedIconIndex,
                (component.predefinedIcons.join("\0") & "\0").cstring,
                component.predefinedIcons.len().int32)

    igDummy(vec2(0.0f, 5.0f))
    igCheckbox("Use custom icon path", addr component.useCustomIcon)
    igBeginDisabled(not component.useCustomIcon)
    igSetNextItemWidth(-1.0f)
    igInputText("##CustomIconPath", addr component.customIconPath[0], 256,
                ImGui_InputTextFlags_None.int32, nil, nil)
    igEndDisabled()

    igDummy(vec2(0.0f, 10.0f))
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
    igInputTextWithHint("##ProductVersion", "1.0.0.0",
                        addr component.productVersion[0], 32,
                        ImGui_InputTextFlags_None.int32, nil, nil)
    igDummy(vec2(0.0f, 5.0f))

    igText("File version")
    igSetNextItemWidth(-1.0f)
    igInputTextWithHint("##FileVersion", "1.0.0.0",
                        addr component.fileVersion[0], 32,
                        ImGui_InputTextFlags_None.int32, nil, nil)
    igDummy(vec2(0.0f, 5.0f))

    igText("Original filename")
    igSetNextItemWidth(-1.0f)
    igInputTextWithHint("##OriginalFilename", "program.exe",
                        addr component.originalFilename[0], 128,
                        ImGui_InputTextFlags_None.int32, nil, nil)

proc drawConfigTab(component: AgentModalComponent, agentType: AgentType) =
    igDummy(vec2(0.0f, 5.0f))

    let (configPath, agentLabel) = case agentType:
        of AGENT_IMPERATOR: (IMPERATOR_ROOT_CLIENT / "nim.cfg", "Imperator")
        of AGENT_MONARCH:   (MONARCH_NIM_CFG, "Monarch")

    igText(fmt"Editing nim.cfg for: {agentLabel}".cstring)
    igTextDisabled(configPath.cstring)
    igDummy(vec2(0.0f, 5.0f))
    igSeparator()
    igDummy(vec2(0.0f, 5.0f))

    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)
    let textHeight = max(200.0f, availableSize.y - 40.0f)

    case agentType:
    of AGENT_IMPERATOR:
        igInputTextMultiline("##NimCfgEditorImperator",
                             addr component.imperatorNimCfg[0],
                             component.imperatorNimCfg.len.uint,
                             vec2(-1.0f, textHeight),
                             ImGui_InputTextFlags_None.int32, nil, nil)
    of AGENT_MONARCH:
        igInputTextMultiline("##NimCfgEditorMonarch",
                             addr component.monarchNimCfg[0],
                             component.monarchNimCfg.len.uint,
                             vec2(-1.0f, textHeight),
                             ImGui_InputTextFlags_None.int32, nil, nil)

    igDummy(vec2(0.0f, 5.0f))
    if igButton("Save to disk", vec2(120.0f, 0.0f)):
        component.saveNimCfgToDisk(agentType)
    igSameLine()
    if igButton("Reload from disk", vec2(120.0f, 0.0f)):
        component.loadNimCfgFromDisk(agentType)
    igSameLine()
    igTextDisabled("(Dynamic flags set automatically on Build)")

proc drawBuildTab(component: AgentModalComponent, listeners: seq[UIListener], agentType: AgentType): AgentBuildInformation =
    igDummy(vec2(0.0f, 5.0f))

    igText("Build log")
    var availableSize: ImVec2
    igGetContentRegionAvail(addr availableSize)
    let buildLogHeight = availableSize.y - 50.0f
    component.buildLog.draw(vec2(-1.0f, buildLogHeight))

    igDummy(vec2(0.0f, 10.0f))
    igGetContentRegionAvail(addr availableSize)
    let textSpacing = igGetStyle().ItemSpacing.x

    igBeginDisabled(component.moduleSelection.items[1].len() == 0)

    if igButton("Build", vec2(availableSize.x * 0.5 - textSpacing * 0.5, 0.0f)):
        component.buildLog.clear()

        var modules: uint32 = 0
        for m in component.moduleSelection.items[1]:
            modules = modules or uint32(parseModuleType(m.name))

        let nimCfgContent = case agentType:
            of AGENT_IMPERATOR: $cstring(component.imperatorNimCfg)
            of AGENT_MONARCH:   $cstring(component.monarchNimCfg)

        result = AgentBuildInformation(
            agentType: cast[AgentType](component.agentType),
            architecture: cast[Architecture](component.architecture),
            listenerId: listeners[component.listener].listenerId,
            payloadType: cast[PayloadType](component.payloadType),
            sleepSettings: SleepSettings(
                sleepDelay: component.sleepDelay,
                jitter: cast[uint32](component.jitter),
                sleepTechnique: cast[SleepObfuscationTechnique](component.sleepMask),
                spoofStack: component.spoofStack,
                workingHours: if component.workingHoursEnabled: component.workingHours
                              else: WorkingHours(enabled: false, startHour: 0, startMinute: 0, endHour: 0, endMinute: 0)
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
                productName:      $cast[cstring](addr component.productName[0]),
                productVersion:   $cast[cstring](addr component.productVersion[0]),
                fileVersion:      $cast[cstring](addr component.fileVersion[0]),
                fileDescription:  $cast[cstring](addr component.fileDescription[0]),
                companyName:      $cast[cstring](addr component.companyName[0]),
                copyright:        $cast[cstring](addr component.copyright[0]),
                originalFilename: $cast[cstring](addr component.originalFilename[0])
            ),
            nimCfgContent: nimCfgContent
        )

        component.saveBuildConfig()

    igEndDisabled()
    igSameLine(0.0f, textSpacing)

    if igButton("Close", vec2(availableSize.x * 0.5 - textSpacing * 0.5, 0.0f)):
        component.resetModalValues()
        igCloseCurrentPopup()

# ---------------------------------------------------------------------------
# Main draw entry point
# ---------------------------------------------------------------------------

proc draw*(component: AgentModalComponent, listeners: seq[UIListener]): AgentBuildInformation =
    let vp = igGetMainViewport()
    var center: ImVec2
    ImGuiViewport_GetCenter(addr center, vp)
    igSetNextWindowPos(center, ImGuiCond_Appearing.int32, vec2(0.5f, 0.5f))
    igSetNextWindowSize(vec2(700.0f, 600.0f), ImGuiCond_Always.int32)

    var show = component.show
    if igBeginPopupModal("Generate Payload", addr show, ImGuiWindowFlags_None.int32):
        defer: igEndPopup()

        component.show = show

        var availableSize: ImVec2
        igGetContentRegionAvail(addr availableSize)

        let agentType = cast[AgentType](component.agentType)

        if not component.configLoaded:
            component.loadNimCfgFromDisk(AGENT_MONARCH)
            component.loadNimCfgFromDisk(AGENT_IMPERATOR)
            component.configLoaded = true

        if igBeginTabBar("##PayloadTabs", ImGuiTabBarFlags_None.int32):

            if igBeginTabItem("Basic", nil, ImGuiTabItemFlags_None.int32):
                drawBasicTab(component, listeners, agentType)
                igEndTabItem()

            if igBeginTabItem("Sleep", nil, ImGuiTabItemFlags_None.int32):
                drawSleepTab(component, agentType)
                igEndTabItem()

            if igBeginTabItem("Evasion", nil, ImGuiTabItemFlags_None.int32):
                drawEvasionTab(component)
                igEndTabItem()

            if igBeginTabItem("Modules", nil, ImGuiTabItemFlags_None.int32):
                drawModulesTab(component)
                igEndTabItem()

            if agentType == AGENT_IMPERATOR:
                if igBeginTabItem("Metadata", nil, ImGuiTabItemFlags_None.int32):
                    drawMetadataTab(component)
                    igEndTabItem()

            if igBeginTabItem("Config", nil, ImGuiTabItemFlags_None.int32):
                drawConfigTab(component, agentType)
                igEndTabItem()

            if igBeginTabItem("Build", nil, ImGuiTabItemFlags_None.int32):
                result = drawBuildTab(component, listeners, agentType)
                igEndTabItem()

            igEndTabBar()
