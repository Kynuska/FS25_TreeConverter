-- TreeConverter.lua
-- Converts static map trees to planted trees that persist in savegames
-- by deleting the static tree and planting a new one via TreePlantManager
-- Also provides a tree map overlay in the in-game map

TreeConverter = {}
TreeConverter.MOD_NAME = g_currentModName or "FS25_TreeConverter"

-- Statistics for logging
TreeConverter.stats = {
    found = 0,
    converted = 0,
    skipped = 0,
    failed = 0
}

-- Trees found during overlap callback
TreeConverter.foundTrees = {}

-- Map overlay data
TreeConverter.mapOverlay = {
    enabled = false,
    treeTypeFilter = {},       -- Which tree types to show/convert
    cacheValid = false,
    dotOverlay = nil,          -- Overlay handle for drawing dots
    dotSize = 4,               -- Size of tree markers in pixels
    typeColors = {},           -- Colors for different tree types
    MAP_TREES = nil,           -- Our map selector index (set dynamically when added)
    treeTypeList = {},         -- Ordered list of tree types for filter list
    numSelectedTreeTypes = 0,  -- Count of selected tree types
    convertActionEventId = nil,-- Input action event ID for convert
    currentFrame = nil         -- Reference to current map frame
}

function TreeConverter:log(level, fmt, ...)
    local prefix = string.format("[%s] ", self.MOD_NAME)
    local msg = string.format(fmt, ...)
    if level == "INFO" then
        print(prefix .. msg)
    elseif level == "WARN" then
        Logging.warning(prefix .. msg)
    elseif level == "ERROR" then
        Logging.error(prefix .. msg)
    else
        print(prefix .. "[" .. level .. "] " .. msg)
    end
end

function TreeConverter:init()
    self:log("INFO", "Initializing TreeConverter...")

    -- Register console commands
    if g_server ~= nil then
        addConsoleCommand("tcConvert", g_i18n:getText("tc_console_convert"), "consoleConvertTrees", self)
        addConsoleCommand("tcConvertRadius", g_i18n:getText("tc_console_convertRadius"), "consoleConvertTreesRadius", self)
        addConsoleCommand("tcConvertAll", g_i18n:getText("tc_console_convertAll"), "consoleConvertAllTrees", self)
        addConsoleCommand("tcConvertSelected", g_i18n:getText("tc_console_convertSelected"), "consoleConvertSelected", self)
        addConsoleCommand("tcCount", g_i18n:getText("tc_console_count"), "consoleCountTrees", self)
        self:log("INFO", "Console commands registered: tcConvert, tcConvertRadius, tcConvertAll, tcConvertSelected, tcCount")
        self:log("INFO", "Open the in-game map and select 'Trees' to see tree locations and select types")
    end

    -- Initialize map overlay
    self:initMapOverlay()

    self:log("INFO", "TreeConverter initialized successfully")
end

-- Add Trees option to the map selector if not already present
function TreeConverter:addTreesOption(frame)
    if frame.mapSelectorTexts == nil then
        return  -- Not initialized yet
    end

    -- Check if "Trees" is already in the list
    local treesText = g_i18n:getText("tc_mapSelector_trees")
    local hasTreesOption = false
    for i, text in ipairs(frame.mapSelectorTexts) do
        if text == treesText then
            hasTreesOption = true
            break
        end
    end

    if not hasTreesOption then
        -- Add "Trees" option to the selector
        table.insert(frame.mapSelectorTexts, treesText)
        frame.mapOverviewSelector:setTexts(frame.mapSelectorTexts)

        -- Store our page index dynamically
        self.mapOverlay.MAP_TREES = #frame.mapSelectorTexts
        self:log("INFO", "Added 'Trees' option to map selector at index %d (now %d options)",
            self.mapOverlay.MAP_TREES, #frame.mapSelectorTexts)

        -- CRITICAL: Clone an extra navigation dot for the subCategoryDotBox
        -- Without this, the navigation and dots won't work correctly
        if frame.subCategoryDotBox ~= nil and #frame.subCategoryDotBox.elements > 0 then
            local newDot = frame.subCategoryDotBox.elements[1]:clone(frame.subCategoryDotBox)
            frame.subCategoryDotBox:addElement(newDot)
            frame.subCategoryDotBox:invalidateLayout()

            -- Update getIsSelected functions for ALL dots
            for dotIndex, dotElement in pairs(frame.subCategoryDotBox.elements) do
                dotElement.getIsSelected = function()
                    return frame.mapOverviewSelector:getState() == dotIndex
                end
            end
            self:log("INFO", "Added navigation dot, now have %d dots", #frame.subCategoryDotBox.elements)
        end
    end

    -- Ensure data tables are initialized for our index
    local treeIndex = self.mapOverlay.MAP_TREES
    if frame.dataTables[treeIndex] == nil then
        frame.dataTables[treeIndex] = {}
    end
    if frame.filterStates[treeIndex] == nil then
        frame.filterStates[treeIndex] = {}
    end
    if frame.numSelectedFilters[treeIndex] == nil then
        frame.numSelectedFilters[treeIndex] = 0
    end
end

-- Initialize the map overlay system (called at mission start for overlay creation)
function TreeConverter:initMapOverlay()
    -- Create a simple 1x1 pixel overlay for drawing dots
    self.mapOverlay.dotOverlay = createImageOverlay("dataS/menu/base/graph_pixel.png")
    self:log("INFO", "Map overlay initialized")
end

-- Set up the frame reference when entering Trees mode
function TreeConverter:setCurrentFrame(frame)
    self.mapOverlay.currentFrame = frame
end

-- Clear frame reference when leaving Trees mode
function TreeConverter:clearCurrentFrame()
    self.mapOverlay.currentFrame = nil
    self.mapOverlay.cacheValid = false  -- Invalidate cache so it rebuilds next time
end

-- Convert action callback
function TreeConverter:onConvertAction()
    if not self.mapOverlay.enabled then
        return
    end

    -- Count selected types
    local selectedTypeCount = 0
    for _, enabled in pairs(self.mapOverlay.treeTypeFilter) do
        if enabled then
            selectedTypeCount = selectedTypeCount + 1
        end
    end

    if selectedTypeCount == 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("tc_warning_noTypesSelected"), 2000)
        return
    end

    -- Count static trees to convert
    local numTrees = self:countSelectedStaticTrees()

    if numTrees == 0 then
        g_currentMission:showBlinkingWarning(g_i18n:getText("tc_warning_noStaticTrees"), 2000)
        return
    end

    local text = string.format(g_i18n:getText("tc_confirm_convert"), numTrees, selectedTypeCount)
    YesNoDialog.show(self.onConvertConfirm, self, text)
end

-- Confirmation callback
function TreeConverter:onConvertConfirm(yes)
    if yes then
        local converted = self:convertSelectedTreeTypes()
        local msg = string.format(g_i18n:getText("tc_message_converted"), converted)
        g_currentMission:showBlinkingWarning(msg, 3000)

        -- Refresh the filter list to update counts
        if self.mapOverlay.currentFrame ~= nil then
            self.mapOverlay.currentFrame.filterList:reloadData()
        end
    end
end

-- Generate distinct colors for each tree type and populate treeTypeList
function TreeConverter:generateTreeTypeColors()
    -- Predefined distinct colors (varied hues to distinguish types)
    local baseColors = {
        {0.2, 0.8, 0.2},   -- Green
        {0.8, 0.4, 0.1},   -- Orange/Brown
        {0.1, 0.6, 0.8},   -- Cyan
        {0.8, 0.2, 0.6},   -- Magenta
        {0.9, 0.9, 0.2},   -- Yellow
        {0.4, 0.2, 0.8},   -- Purple
        {0.1, 0.4, 0.1},   -- Dark green
        {0.8, 0.6, 0.4},   -- Tan
        {0.2, 0.8, 0.8},   -- Teal
        {0.6, 0.8, 0.2},   -- Lime
        {0.8, 0.2, 0.2},   -- Red
        {0.4, 0.6, 0.8},   -- Light blue
    }

    self.mapOverlay.treeTypeList = {}
    self.mapOverlay.treeTypeFilter = {}
    self.mapOverlay.typeColors = {}
    self.mapOverlay.numSelectedTreeTypes = 0

    -- Assign colors to tree types
    if g_treePlantManager ~= nil and g_treePlantManager.treeTypes ~= nil then
        local colorIndex = 1

        -- First pass: collect all tree types with colors
        local tempList = {}
        for _, treeType in ipairs(g_treePlantManager.treeTypes) do
            local color = baseColors[colorIndex] or {math.random(), math.random() * 0.5 + 0.5, math.random()}
            colorIndex = colorIndex + 1
            if colorIndex > #baseColors then
                colorIndex = 1
            end

            table.insert(tempList, {
                treeTypeIndex = treeType.index,  -- Original tree type index for conversion
                name = treeType.title or treeType.name,
                color = color
            })
        end

        -- Sort by name for consistent display
        table.sort(tempList, function(a, b)
            return a.name < b.name
        end)

        -- Second pass: build final lists with sequential indices
        -- This matches how the base game expects dataTables/filterStates to work
        for i, item in ipairs(tempList) do
            -- treeTypeList uses sequential index for filter list display
            -- but stores treeTypeIndex for actual tree conversion
            self.mapOverlay.treeTypeList[i] = {
                -- Data format expected by base game's populateCellForItemInSection:
                description = item.name,  -- Used for cell name display
                colors = {
                    [false] = {r = item.color[1], g = item.color[2], b = item.color[3], a = 1},
                    [true] = {r = item.color[1], g = item.color[2], b = item.color[3], a = 1}  -- Same for colorblind
                },
                -- Our custom fields:
                treeTypeIndex = item.treeTypeIndex
            }

            -- filterStates uses sequential index (1, 2, 3...) like the base game
            self.mapOverlay.treeTypeFilter[i] = true

            -- Store color by original tree type index for map overlay rendering
            self.mapOverlay.typeColors[item.treeTypeIndex] = item.color

            self.mapOverlay.numSelectedTreeTypes = self.mapOverlay.numSelectedTreeTypes + 1
        end

    else
        self:log("WARN", "TreePlantManager or treeTypes not available")
    end
end

-- Build cache of all trees (static for conversion, planted for display)
function TreeConverter:buildTreeCache()
    if self.mapOverlay.cacheValid then
        return  -- Cache is still valid
    end

    self.mapOverlay.cachedStaticTrees = {}  -- Static trees (can be converted)
    self.mapOverlay.cachedPlantedTrees = {} -- Planted trees (display only)
    self.mapOverlay.totalStaticCount = 0

    -- Find all static trees (convertible)
    local staticTrees = self:findAllTrees()
    for _, shapeId in ipairs(staticTrees) do
        if entityExists(shapeId) then
            local treeTypeDesc = self:getTreeTypeFromShape(shapeId)
            if treeTypeDesc ~= nil then
                local typeIndex = treeTypeDesc.index
                if self.mapOverlay.cachedStaticTrees[typeIndex] == nil then
                    self.mapOverlay.cachedStaticTrees[typeIndex] = {}
                end
                local treeNode = getParent(shapeId)
                if treeNode ~= nil and treeNode ~= 0 then
                    local x, y, z = getWorldTranslation(treeNode)
                    table.insert(self.mapOverlay.cachedStaticTrees[typeIndex], {x = x, y = y, z = z, shapeId = shapeId})
                    self.mapOverlay.totalStaticCount = self.mapOverlay.totalStaticCount + 1
                end
            end
        end
    end

    -- Also collect planted trees from TreePlantManager for display
    local plantedCount = 0
    if g_treePlantManager ~= nil and g_treePlantManager.treesData ~= nil then
        -- Collect from growingTrees
        for _, tree in ipairs(g_treePlantManager.treesData.growingTrees or {}) do
            local typeIndex = tree.treeType
            if self.mapOverlay.cachedPlantedTrees[typeIndex] == nil then
                self.mapOverlay.cachedPlantedTrees[typeIndex] = {}
            end
            table.insert(self.mapOverlay.cachedPlantedTrees[typeIndex], {x = tree.x, y = tree.y, z = tree.z})
            plantedCount = plantedCount + 1
        end
        -- Collect from splitTrees (mature planted trees)
        for _, tree in ipairs(g_treePlantManager.treesData.splitTrees or {}) do
            local typeIndex = tree.treeType
            if self.mapOverlay.cachedPlantedTrees[typeIndex] == nil then
                self.mapOverlay.cachedPlantedTrees[typeIndex] = {}
            end
            table.insert(self.mapOverlay.cachedPlantedTrees[typeIndex], {x = tree.x, y = tree.y, z = tree.z})
            plantedCount = plantedCount + 1
        end
    end

    self.mapOverlay.cacheValid = true

    self:log("INFO", "Tree cache rebuilt: %d static trees, %d planted trees", self.mapOverlay.totalStaticCount, plantedCount)
end

-- Helper to draw trees from a cache table
function TreeConverter:drawTreesFromCache(cache, ingameMap, mapWidth, mapHeight, mapPosX, mapPosY, worldSizeX, worldSizeZ, mapExtensionScaleFactor, mapExtensionOffsetX, dotSizeX, dotSizeY, alpha)
    for typeIndex, treeList in pairs(cache) do
        -- Find the filter index for this tree type
        local filterEnabled = false
        for filterIdx, treeData in ipairs(self.mapOverlay.treeTypeList) do
            if treeData.treeTypeIndex == typeIndex and self.mapOverlay.treeTypeFilter[filterIdx] then
                filterEnabled = true
                break
            end
        end

        if filterEnabled then
            local color = self.mapOverlay.typeColors[typeIndex] or {0.2, 0.8, 0.2}
            setOverlayColor(self.mapOverlay.dotOverlay, color[1], color[2], color[3], alpha)

            for _, treeData in ipairs(treeList) do
                -- Convert world position to screen position
                local screenX = ((treeData.x / worldSizeX + 0.5) * mapExtensionScaleFactor + mapExtensionOffsetX) * mapWidth + mapPosX
                local screenY = (1 - ((treeData.z / worldSizeZ + 0.5) * mapExtensionScaleFactor + mapExtensionOffsetX)) * mapHeight + mapPosY

                -- Center the dot on the position
                screenX = screenX - dotSizeX * 0.5
                screenY = screenY - dotSizeY * 0.5

                -- Draw the dot
                renderOverlay(self.mapOverlay.dotOverlay, screenX, screenY, dotSizeX, dotSizeY)
            end
        end
    end
end

-- Draw tree overlay on the map
function TreeConverter:drawTreeOverlay(frame, element, ingameMap)
    if not self.mapOverlay.enabled then
        return
    end

    if self.mapOverlay.dotOverlay == nil or self.mapOverlay.dotOverlay == 0 then
        -- Try to create it now if not created yet
        self.mapOverlay.dotOverlay = createImageOverlay("dataS/menu/base/graph_pixel.png")
        if self.mapOverlay.dotOverlay == nil or self.mapOverlay.dotOverlay == 0 then
            return
        end
    end

    -- Build cache if needed (rebuilds when entering Trees view)
    self:buildTreeCache()

    -- Get map layout info from the ingameMap passed to us
    local fullScreenLayout = ingameMap.fullScreenLayout
    if fullScreenLayout == nil then
        return
    end

    local mapWidth, mapHeight = fullScreenLayout:getMapSize()
    local mapPosX, mapPosY = fullScreenLayout:getMapPosition()

    -- Use ingameMap's world size for proper coordinate conversion
    local worldSizeX = ingameMap.worldSizeX
    local worldSizeZ = ingameMap.worldSizeZ
    local mapExtensionScaleFactor = ingameMap.mapExtensionScaleFactor or 1
    local mapExtensionOffsetX = ingameMap.mapExtensionOffsetX or 0

    -- Calculate dot size in screen coordinates
    local dotSizeX = self.mapOverlay.dotSize * g_pixelSizeX
    local dotSizeY = self.mapOverlay.dotSize * g_pixelSizeY

    -- Draw planted trees (slightly transparent)
    if self.mapOverlay.cachedPlantedTrees then
        self:drawTreesFromCache(self.mapOverlay.cachedPlantedTrees, ingameMap, mapWidth, mapHeight, mapPosX, mapPosY, worldSizeX, worldSizeZ, mapExtensionScaleFactor, mapExtensionOffsetX, dotSizeX, dotSizeY, 0.6)
    end

    -- Draw static trees (full opacity) on top
    if self.mapOverlay.cachedStaticTrees then
        self:drawTreesFromCache(self.mapOverlay.cachedStaticTrees, ingameMap, mapWidth, mapHeight, mapPosX, mapPosY, worldSizeX, worldSizeZ, mapExtensionScaleFactor, mapExtensionOffsetX, dotSizeX, dotSizeY, 0.9)
    end

    -- Update convert button visibility based on static tree count
    self:updateConvertButtonVisibility()
end

-- Convert trees of selected types only
function TreeConverter:convertSelectedTreeTypes()
    if not self.mapOverlay.cacheValid then
        self:buildTreeCache()
    end

    local treesToConvert = {}
    for typeIndex, treeList in pairs(self.mapOverlay.cachedStaticTrees or {}) do
        -- Find the filter index for this tree type (same logic as drawTreeOverlay)
        local filterEnabled = false
        for filterIdx, treeData in ipairs(self.mapOverlay.treeTypeList) do
            if treeData.treeTypeIndex == typeIndex and self.mapOverlay.treeTypeFilter[filterIdx] then
                filterEnabled = true
                break
            end
        end

        if filterEnabled then
            for _, treeData in ipairs(treeList) do
                table.insert(treesToConvert, treeData.shapeId)
            end
        end
    end

    if #treesToConvert == 0 then
        self:log("INFO", "No trees selected for conversion")
        return 0
    end

    local converted = self:convertTrees(treesToConvert)
    self.mapOverlay.cacheValid = false  -- Invalidate cache after conversion
    return converted
end

-- Count static trees for selected filter types
function TreeConverter:countSelectedStaticTrees()
    local count = 0
    for typeIndex, treeList in pairs(self.mapOverlay.cachedStaticTrees or {}) do
        for filterIdx, treeData in ipairs(self.mapOverlay.treeTypeList) do
            if treeData.treeTypeIndex == typeIndex and self.mapOverlay.treeTypeFilter[filterIdx] then
                count = count + #treeList
                break
            end
        end
    end
    return count
end

-- Update convert button visibility based on whether there are static trees to convert
function TreeConverter:updateConvertButtonVisibility()
    if self.mapOverlay.convertButton == nil then
        return
    end

    local selectedStaticCount = self:countSelectedStaticTrees()
    self.mapOverlay.convertButton:setVisible(selectedStaticCount > 0)
end

-- Reset statistics
function TreeConverter:resetStats()
    self.stats.found = 0
    self.stats.converted = 0
    self.stats.skipped = 0
    self.stats.failed = 0
end

-- Log current statistics
function TreeConverter:logStats()
    self:log("INFO", "Conversion complete:")
    self:log("INFO", "  Found: %d static trees", self.stats.found)
    self:log("INFO", "  Converted: %d trees", self.stats.converted)
    self:log("INFO", "  Skipped: %d (no matching tree type)", self.stats.skipped)
    self:log("INFO", "  Failed: %d", self.stats.failed)
end

-- Check if a shape is a static tree that can be converted
function TreeConverter:isConvertibleTree(shape)
    -- Must be a mesh split shape
    if not getHasClassId(shape, ClassIds.MESH_SPLIT_SHAPE) then
        return false, "not a split shape"
    end

    -- Must have a valid split type (tree type)
    local splitType = getSplitType(shape)
    if splitType == 0 then
        return false, "no split type"
    end

    -- Must be static (not already cut/dynamic)
    if getRigidBodyType(shape) ~= RigidBodyType.STATIC then
        return false, "not static"
    end

    -- Must not already be split (cut)
    if getIsSplitShapeSplit(shape) then
        return false, "already split"
    end

    -- Must NOT already be a planted tree (managed by TreePlantManager)
    -- Planted trees are parented under treesData.rootNode (may be several levels deep)
    if g_treePlantManager ~= nil and g_treePlantManager.treesData ~= nil then
        local treesRootNode = g_treePlantManager.treesData.rootNode
        if treesRootNode ~= nil and treesRootNode ~= 0 then
            -- Walk up the parent chain to see if any ancestor is the trees root
            local currentNode = getParent(shape)
            local depth = 0
            local maxDepth = 10  -- Safety limit
            while currentNode ~= nil and currentNode ~= 0 and depth < maxDepth do
                if currentNode == treesRootNode then
                    return false, "already planted"
                end
                currentNode = getParent(currentNode)
                depth = depth + 1
            end
        end
    end

    return true, nil
end

-- Get tree type info from a static tree shape
function TreeConverter:getTreeTypeFromShape(shape)
    local splitTypeIndex = getSplitType(shape)
    if splitTypeIndex == 0 then
        return nil, nil
    end

    local treeTypeDesc = g_treePlantManager:getTreeTypeDescFromSplitType(splitTypeIndex)
    if treeTypeDesc == nil then
        -- Try to get split type name for logging
        local splitTypeName = g_splitShapeManager:getSplitTypeNameByIndex(splitTypeIndex)
        return nil, splitTypeName
    end

    return treeTypeDesc, nil
end

-- Detect growth stage and variation by matching the node name against stage filenames
-- Returns growthStateI, variationIndex
function TreeConverter:detectGrowthStageAndVariation(shape, treeTypeDesc)
    -- Get the tree node name (parent of the split shape)
    local treeNode = getParent(shape)
    local nodeName = treeNode and getName(treeNode) or nil
    local nodeNameLower = nodeName and nodeName:lower() or ""

    -- Search through all stages and variations for a matching filename
    for stageIndex, variations in ipairs(treeTypeDesc.stages) do
        for variationIndex, variation in ipairs(variations) do
            if variation.filename then
                -- Extract the base name from the filename (e.g., "americanElm_stage04" from "trees/americanElm/americanElm_stage04.i3d")
                local baseName = variation.filename:match("([^/]+)%.i3d$")
                if baseName then
                    local baseNameLower = baseName:lower()
                    -- Check if the node name matches or contains the base name
                    if nodeNameLower == baseNameLower or nodeNameLower:find(baseNameLower, 1, true) then
                        return stageIndex, variationIndex
                    end
                end
            end
        end
    end

    -- Fallback: use max stage with random variation
    local maxStage = #treeTypeDesc.stages
    local numVariations = #treeTypeDesc.stages[maxStage]
    return maxStage, math.random(1, numVariations)
end

-- Convert a single static tree to a planted tree
-- Returns true on success, false on failure
function TreeConverter:convertTree(shape)
    -- Validate
    local isValid, reason = self:isConvertibleTree(shape)
    if not isValid then
        self:log("DEBUG", "Skipping shape %d: %s", shape, reason)
        return false, reason
    end

    -- Get tree type
    local treeTypeDesc, splitTypeName = self:getTreeTypeFromShape(shape)
    if treeTypeDesc == nil then
        self:log("WARN", "No tree type found for split type '%s' (shape %d)", tostring(splitTypeName), shape)
        self.stats.skipped = self.stats.skipped + 1
        return false, "no tree type mapping"
    end

    -- Get the parent node (TransformGroup that contains the split shape and LODs)
    -- This is important: we need to delete the parent, not just the shape,
    -- otherwise LOD nodes would be left behind (like LumberJack discovered)
    local treeNode = getParent(shape)
    if treeNode == nil or treeNode == 0 then
        self:log("WARN", "Could not get parent node for shape %d", shape)
        self.stats.failed = self.stats.failed + 1
        return false, "no parent node"
    end

    -- Get position and rotation from the parent node (like replaceWithTreeType does)
    local x, y, z = getWorldTranslation(treeNode)
    local rx, ry, rz = getWorldRotation(treeNode)

    -- Detect growth stage and variation by matching node name against stage filenames
    local growthStage, variationIndex = self:detectGrowthStageAndVariation(shape, treeTypeDesc)
    local maxStage = #treeTypeDesc.stages
    local isGrowing = growthStage < maxStage

    -- Remove from known split shapes (important for persistence)
    g_currentMission:removeKnownSplitShape(shape)

    -- Notify TreePlantManager
    g_treePlantManager:removingSplitShape(shape)

    -- Delete the parent node (this deletes the shape AND any LOD siblings)
    delete(treeNode)

    -- Plant new tree with detected stage
    local newTreeNode = g_treePlantManager:plantTree(
        treeTypeDesc.index,  -- treeTypeIndex
        x, y, z,             -- position
        rx, ry, rz,          -- rotation
        growthStage,         -- growthStateI (detected from original)
        variationIndex,      -- variationIndex
        isGrowing,           -- isGrowing (true if not at max stage)
        nil,                 -- nextGrowthTargetHour
        nil                  -- existingSplitShapeFileId
    )

    if newTreeNode ~= nil then
        self.stats.converted = self.stats.converted + 1
        return true, nil
    else
        self.stats.failed = self.stats.failed + 1
        return false, "plantTree failed"
    end
end

-- Overlap callback for finding trees
function TreeConverter.overlapCallback(self, transformId)
    local isValid, _ = self:isConvertibleTree(transformId)
    if isValid then
        table.insert(self.foundTrees, transformId)
    end
end

-- Find all static trees in a sphere
function TreeConverter:findTreesInRadius(x, y, z, radius)
    self.foundTrees = {}
    overlapSphere(x, y, z, radius, "overlapCallback", self, CollisionFlag.TREE, false, false, true, false)
    return self.foundTrees
end

-- Find all static trees on the entire map
function TreeConverter:findAllTrees()
    self.foundTrees = {}

    -- Get terrain size
    local terrainSize = 2048  -- Default
    if g_currentMission.terrainRootNode ~= nil then
        terrainSize = getTerrainSize(g_currentMission.terrainRootNode)
    end

    local halfSize = terrainSize / 2

    -- Scan in a grid pattern with overlapping spheres
    local scanRadius = 100
    local stepSize = scanRadius * 1.5  -- Overlap a bit

    self:log("INFO", "Scanning map (size %d) for static trees...", terrainSize)

    local scannedAreas = 0
    for scanX = -halfSize, halfSize, stepSize do
        for scanZ = -halfSize, halfSize, stepSize do
            -- Use terrain height at this position
            local scanY = getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, scanX, 0, scanZ) + 50
            overlapSphere(scanX, scanY, scanZ, scanRadius, "overlapCallback", self, CollisionFlag.TREE, false, false, true, false)
            scannedAreas = scannedAreas + 1
        end
    end

    -- Remove duplicates (trees may be found by multiple overlapping spheres)
    local uniqueTrees = {}
    local seen = {}
    for _, treeId in ipairs(self.foundTrees) do
        if not seen[treeId] then
            seen[treeId] = true
            table.insert(uniqueTrees, treeId)
        end
    end

    self:log("INFO", "Scanned %d areas, found %d unique static trees", scannedAreas, #uniqueTrees)
    self.foundTrees = uniqueTrees
    return uniqueTrees
end

-- Convert trees in a list
function TreeConverter:convertTrees(trees)
    self:resetStats()
    self.stats.found = #trees

    self:log("INFO", "Converting %d static trees...", #trees)

    -- Track tree types for summary
    local typeCount = {}
    local notExistCount = 0
    local convertFailCount = 0

    -- Progress logging interval based on total count
    local progressInterval = #trees > 1000 and 1000 or 100

    for i, treeId in ipairs(trees) do
        -- Check if tree still exists (may have been deleted by previous conversion)
        if entityExists(treeId) then
            local treeTypeDesc = self:getTreeTypeFromShape(treeId)
            local typeName = treeTypeDesc and treeTypeDesc.name or "unknown"

            local success = self:convertTree(treeId)

            if success then
                typeCount[typeName] = (typeCount[typeName] or 0) + 1
            else
                convertFailCount = convertFailCount + 1
            end
        else
            notExistCount = notExistCount + 1
        end

        -- Progress logging
        if i % progressInterval == 0 then
            self:log("INFO", "Progress: %d/%d trees processed...", i, #trees)
        end
    end

    self:log("INFO", "Conversion details: %d not existing, %d failed to convert", notExistCount, convertFailCount)

    -- Log summary by type
    self:log("INFO", "Conversion by tree type:")
    for typeName, count in pairs(typeCount) do
        self:log("INFO", "  %s: %d", typeName, count)
    end

    self:logStats()

    -- Update collision maps
    g_densityMapHeightManager:consoleCommandUpdateTipCollisions()

    return self.stats.converted
end

-- Console command: Convert trees at player position with default radius
function TreeConverter:consoleConvertTrees()
    return self:consoleConvertTreesRadius(50)
end

-- Console command: Convert trees in radius around player
function TreeConverter:consoleConvertTreesRadius(radiusStr)
    local radius = tonumber(radiusStr) or 50

    if g_currentMission == nil or g_localPlayer == nil then
        return "Error: Mission not loaded"
    end

    local x, y, z = getWorldTranslation(g_localPlayer.rootNode)
    self:log("INFO", "Finding static trees within %dm of player at (%.1f, %.1f, %.1f)", radius, x, y, z)

    local trees = self:findTreesInRadius(x, y, z, radius)
    self:log("INFO", "Found %d static trees in radius", #trees)

    if #trees == 0 then
        return "No static trees found in radius"
    end

    local converted = self:convertTrees(trees)
    return string.format("Converted %d/%d static trees to planted trees", converted, #trees)
end

-- Console command: Convert ALL static trees on the map
function TreeConverter:consoleConvertAllTrees()
    if g_currentMission == nil then
        return "Error: Mission not loaded"
    end

    self:log("INFO", "Starting full map tree conversion...")

    local trees = self:findAllTrees()

    if #trees == 0 then
        return "No static trees found on map"
    end

    local converted = self:convertTrees(trees)
    return string.format("Converted %d/%d static trees to planted trees. Save game to persist!", converted, #trees)
end

-- Console command: Count static trees in radius (no conversion)
function TreeConverter:consoleCountTrees(radiusStr)
    local radius = tonumber(radiusStr) or 50

    if g_currentMission == nil or g_localPlayer == nil then
        return "Error: Mission not loaded"
    end

    local x, y, z = getWorldTranslation(g_localPlayer.rootNode)
    local trees = self:findTreesInRadius(x, y, z, radius)

    -- Count by type
    local typeCount = {}
    for _, treeId in ipairs(trees) do
        local treeTypeDesc = self:getTreeTypeFromShape(treeId)
        local typeName = treeTypeDesc and treeTypeDesc.name or "unknown"
        typeCount[typeName] = (typeCount[typeName] or 0) + 1
    end

    self:log("INFO", "Static trees within %dm:", radius)
    for typeName, count in pairs(typeCount) do
        self:log("INFO", "  %s: %d", typeName, count)
    end

    return string.format("Found %d static trees within %dm radius", #trees, radius)
end

-- Console command: Convert only selected tree types (selected in map overlay)
function TreeConverter:consoleConvertSelected()
    if g_currentMission == nil then
        return "Error: Mission not loaded"
    end

    -- Count selected types
    local selectedCount = 0
    for _, enabled in pairs(self.mapOverlay.treeTypeFilter) do
        if enabled then
            selectedCount = selectedCount + 1
        end
    end

    if selectedCount == 0 then
        return "No tree types selected. Open map and select 'Trees' to choose types."
    end

    self:log("INFO", "Converting %d selected tree types...", selectedCount)
    local converted = self:convertSelectedTreeTypes()
    return string.format("Converted %d trees of selected types. Save game to persist!", converted)
end

-- Cleanup on unload
function TreeConverter:cleanup()
    removeConsoleCommand("tcConvert")
    removeConsoleCommand("tcConvertRadius")
    removeConsoleCommand("tcConvertAll")
    removeConsoleCommand("tcConvertSelected")
    removeConsoleCommand("tcCount")

    -- Clear frame reference
    self:clearCurrentFrame()

    -- Clean up overlay
    if self.mapOverlay.dotOverlay ~= nil and self.mapOverlay.dotOverlay ~= 0 then
        delete(self.mapOverlay.dotOverlay)
        self.mapOverlay.dotOverlay = nil
    end

    self:log("INFO", "TreeConverter unloaded")
end

-- Initialize when mission starts
Mission00.onStartMission = Utils.appendedFunction(Mission00.onStartMission, function()
    TreeConverter:init()
end)

-- Cleanup when mission ends
FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, function()
    TreeConverter:cleanup()
end)

-- =============================================================================
-- HOOK INSTALLATION AT SCRIPT LOAD TIME
-- These hooks MUST be installed when the script loads (like PrecisionFarming does)
-- NOT during Mission00.onStartMission, which is too late
-- =============================================================================

-- Hook setupMapOverview to add "Trees" option to the selector
InGameMenuMapFrame.setupMapOverview = Utils.appendedFunction(InGameMenuMapFrame.setupMapOverview, function(frame)
    TreeConverter:addTreesOption(frame)

    -- Set callback on the selector widget itself
    frame.mapOverviewSelector.onClickCallback = function(_, state)
        frame:onClickMapOverviewSelector(state)
    end

    -- Update the draw callback to point to the class method (which is now hooked)
    if frame.ingameMap ~= nil then
        frame.ingameMap.onDrawPostIngameMapCallback = InGameMenuMapFrame.onDrawPostIngameMap
    end
end)

-- Hook onFrameOpen to ensure our option is always present
InGameMenuMapFrame.onFrameOpen = Utils.prependedFunction(InGameMenuMapFrame.onFrameOpen, function(frame)
    TreeConverter:addTreesOption(frame)
end)

-- Hook onClickMapOverviewSelector to handle Trees selection
InGameMenuMapFrame.onClickMapOverviewSelector = Utils.appendedFunction(InGameMenuMapFrame.onClickMapOverviewSelector, function(frame, state)
    -- Handle Trees category
    if state == TreeConverter.mapOverlay.MAP_TREES then
        TreeConverter.mapOverlay.enabled = true

        -- Regenerate tree type list on demand
        if #TreeConverter.mapOverlay.treeTypeList == 0 then
            TreeConverter:generateTreeTypeColors()
            -- Update frame's data tables with fresh data
            frame.dataTables[TreeConverter.mapOverlay.MAP_TREES] = TreeConverter.mapOverlay.treeTypeList
            frame.filterStates[TreeConverter.mapOverlay.MAP_TREES] = TreeConverter.mapOverlay.treeTypeFilter
        end
        frame.numSelectedFilters[TreeConverter.mapOverlay.MAP_TREES] = TreeConverter.mapOverlay.numSelectedTreeTypes

        frame.filterListContainer:setVisible(true)
        frame.buttonDeselectAllContainer:setVisible(true)
        -- Update select/deselect all button text
        if TreeConverter.mapOverlay.numSelectedTreeTypes == 0 then
            frame.buttonDeselectAllText:setText(g_i18n:getText("button_selectAll"))
        else
            frame.buttonDeselectAllText:setText(g_i18n:getText("button_deselectAll"))
        end
        frame.filterList:reloadData()

        -- Store frame reference
        TreeConverter:setCurrentFrame(frame)

        -- Create our Convert button next to Deselect All
        TreeConverter:createConvertButton(frame)
    else
        TreeConverter.mapOverlay.enabled = false
        -- Clear frame reference
        TreeConverter:clearCurrentFrame()

        -- Remove our Convert button
        TreeConverter:removeConvertButton()
    end
end)

-- Hook onDrawPostIngameMap to draw tree overlay
InGameMenuMapFrame.onDrawPostIngameMap = Utils.appendedFunction(InGameMenuMapFrame.onDrawPostIngameMap, function(frame, element, ingameMap)
    TreeConverter:drawTreeOverlay(frame, element, ingameMap)
end)

-- Hook getNumberOfItemsInSection to return our tree count
local originalGetNumberOfItemsInSection = InGameMenuMapFrame.getNumberOfItemsInSection
InGameMenuMapFrame.getNumberOfItemsInSection = function(frame, list, section)
    local treeIndex = TreeConverter.mapOverlay.MAP_TREES
    if list == frame.filterList and treeIndex ~= nil and frame.mapOverviewSelector:getState() == treeIndex then
        return #TreeConverter.mapOverlay.treeTypeList
    end
    return originalGetNumberOfItemsInSection(frame, list, section)
end

-- Hook populateCellForItemInSection to render tree type items
local originalPopulateCellForItemInSection = InGameMenuMapFrame.populateCellForItemInSection
InGameMenuMapFrame.populateCellForItemInSection = function(frame, list, section, index, cell)
    local treeIndex = TreeConverter.mapOverlay.MAP_TREES
    if list == frame.filterList and treeIndex ~= nil and frame.mapOverviewSelector:getState() == treeIndex then
        local treeData = TreeConverter.mapOverlay.treeTypeList[index]
        if treeData ~= nil then
            -- Set up getIsSelected function
            local function getIsSelectedFunc()
                return TreeConverter.mapOverlay.treeTypeFilter[index] == true
            end

            -- Set name
            cell:getAttribute("name"):setText(treeData.description)

            -- Set up icon (hide it, we just use iconBg for color)
            local icon = cell:getAttribute("icon")
            icon:setVisible(false)
            icon.getIsSelected = getIsSelectedFunc

            -- Set up iconBg with color
            local iconBg = cell:getAttribute("iconBg")
            iconBg.getIsSelected = getIsSelectedFunc

            -- Get color from our data
            local colorData = treeData.colors[frame.isColorBlindMode]
            frame:assignItemColors(iconBg, {{colorData.r, colorData.g, colorData.b, colorData.a}})
        end
        return
    end
    return originalPopulateCellForItemInSection(frame, list, section, index, cell)
end

-- Hook onClickList for filter list selection
local originalOnClickList = InGameMenuMapFrame.onClickList
InGameMenuMapFrame.onClickList = function(frame, list, section, index, listElement)
    local treeIndex = TreeConverter.mapOverlay.MAP_TREES
    local isTreeState = (treeIndex ~= nil and frame.mapOverviewSelector:getState() == treeIndex)

    -- Call original handler
    originalOnClickList(frame, list, section, index, listElement)

    -- Sync our count if this was the Trees filter
    if isTreeState and list == frame.filterList then
        -- Sync filter state from frame back to our data
        TreeConverter.mapOverlay.treeTypeFilter[index] = frame.filterStates[treeIndex][index]

        -- Recalculate count
        local count = 0
        for i = 1, #TreeConverter.mapOverlay.treeTypeList do
            if TreeConverter.mapOverlay.treeTypeFilter[i] then
                count = count + 1
            end
        end
        TreeConverter.mapOverlay.numSelectedTreeTypes = count
    end
end

-- Hook getHasChangeableFilterList to return true for Trees
local originalGetHasChangeableFilterList = InGameMenuMapFrame.getHasChangeableFilterList
InGameMenuMapFrame.getHasChangeableFilterList = function(frame)
    if frame.mapOverviewSelector:getState() == TreeConverter.mapOverlay.MAP_TREES then
        return true
    end
    return originalGetHasChangeableFilterList(frame)
end

-- Hook onClickDeselectAll for select/deselect all tree types
local originalOnClickDeselectAll = InGameMenuMapFrame.onClickDeselectAll
InGameMenuMapFrame.onClickDeselectAll = function(frame, exceptionSection, exceptionIndex)
    if frame.mapOverviewSelector:getState() == TreeConverter.mapOverlay.MAP_TREES then
        local selectAll = TreeConverter.mapOverlay.numSelectedTreeTypes == 0
        -- Use sequential indices (1, 2, 3...) like base game
        for i = 1, #TreeConverter.mapOverlay.treeTypeList do
            TreeConverter.mapOverlay.treeTypeFilter[i] = selectAll
        end
        if selectAll then
            TreeConverter.mapOverlay.numSelectedTreeTypes = #TreeConverter.mapOverlay.treeTypeList
            frame.buttonDeselectAllText:setText(g_i18n:getText("button_deselectAll"))
        else
            TreeConverter.mapOverlay.numSelectedTreeTypes = 0
            frame.buttonDeselectAllText:setText(g_i18n:getText("button_selectAll"))
        end
        frame.numSelectedFilters[TreeConverter.mapOverlay.MAP_TREES] = TreeConverter.mapOverlay.numSelectedTreeTypes
        frame.filterList:reloadData()
        return
    end
    return originalOnClickDeselectAll(frame, exceptionSection, exceptionIndex)
end

-- Create the Convert button by cloning the Deselect All button
function TreeConverter:createConvertButton(frame)
    if self.mapOverlay.convertButton ~= nil then
        return  -- Already created
    end

    -- Clone the buttonDeselectAllContainer
    if frame.buttonDeselectAllContainer ~= nil then
        local convertContainer = frame.buttonDeselectAllContainer:clone(frame.buttonDeselectAllContainer.parent)

        -- Get the height of one button for positioning
        local buttonHeight = frame.buttonDeselectAllContainer.absSize[2]
        local spacing = 5 * g_pixelSizeY

        -- Store original filter list height before modifying
        self.mapOverlay.originalFilterListHeight = frame.filterList.size[2]

        -- Reduce the filter list height to make room for the Convert button
        local newFilterListHeight = self.mapOverlay.originalFilterListHeight - buttonHeight - spacing
        frame.filterList:setSize(nil, newFilterListHeight)

        -- Position Convert button above Deselect All (Deselect All stays in original position)
        local deselectY = frame.buttonDeselectAllContainer.position[2]
        local convertY = deselectY + buttonHeight + spacing
        convertContainer:setPosition(nil, convertY)

        -- Find the text element and button element
        for _, element in ipairs(convertContainer.elements) do
            -- Update the text (it's the Text element, not Button)
            if element.profile ~= nil and string.find(element.profile, "Text") then
                element:setText(g_i18n:getText("tc_button_convertSelected"))
            end
            -- Find the Button element and update its callback
            if element.profile ~= nil and string.find(element.profile, "Button") then
                element.onClickCallback = function()
                    TreeConverter:onConvertAction()
                end
                -- Set the input action for the keybind display
                if element.setInputAction ~= nil then
                    element:setInputAction(InputAction.MENU_EXTRA_2)
                end
            end
        end

        self.mapOverlay.convertButton = convertContainer
        convertContainer:setVisible(true)

        -- Register the input action so the keybind works
        local _, eventId = g_inputBinding:registerActionEvent(InputAction.MENU_EXTRA_2, self, self.onConvertAction, false, true, false, true)
        if eventId ~= nil then
            self.mapOverlay.convertActionEventId = eventId
        end
    end
end

-- Remove the Convert button
function TreeConverter:removeConvertButton()
    if self.mapOverlay.convertButton ~= nil then
        self.mapOverlay.convertButton:delete()
        self.mapOverlay.convertButton = nil
    end

    -- Restore original filter list height
    if self.mapOverlay.currentFrame ~= nil then
        local frame = self.mapOverlay.currentFrame
        if self.mapOverlay.originalFilterListHeight ~= nil then
            frame.filterList:setSize(nil, self.mapOverlay.originalFilterListHeight)
            self.mapOverlay.originalFilterListHeight = nil
        end
    end

    -- Clean up action event
    if self.mapOverlay.convertActionEventId ~= nil then
        g_inputBinding:removeActionEvent(self.mapOverlay.convertActionEventId)
        self.mapOverlay.convertActionEventId = nil
    end
end
