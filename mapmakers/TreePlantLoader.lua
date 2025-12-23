-- TreePlantLoader.lua
-- Loads default treePlant.xml for new games
--
-- USAGE FOR MAP MAKERS:
-- 1. Run convert_static_trees.py on your map to generate treePlant.xml
-- 2. Place treePlant.xml in defaultSavegame/ folder in your map
-- 3. Copy this script to your map's scripts folder
-- 4. Add to your modDesc.xml:
--    <extraSourceFiles>
--        <sourceFile filename="scripts/TreePlantLoader.lua"/>
--    </extraSourceFiles>
--
-- The script hooks TreePlantManager:loadFromXMLFile to provide default trees
-- when starting a new game or when the savegame's treePlant.xml is empty.

print("TreePlantLoader: Script file being parsed...")

-- Hook into TreePlantManager:loadFromXMLFile to provide default trees for new games
local originalLoadFromXMLFile = TreePlantManager.loadFromXMLFile

function TreePlantManager:loadFromXMLFile(xmlFilename)
    print("TreePlantLoader: loadFromXMLFile called with: " .. tostring(xmlFilename))

    -- If no file provided (new game), try to load our default trees
    if xmlFilename == nil then
        print("TreePlantLoader: No xmlFilename provided (new game)")

        -- Find our mod's default treePlant.xml
        if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.map ~= nil then
            local modDir = g_currentMission.missionInfo.map.baseDirectory
            print("TreePlantLoader: Mod directory: " .. tostring(modDir))

            if modDir ~= nil then
                local defaultFile = modDir .. "defaultSavegame/treePlant.xml"
                print("TreePlantLoader: Checking for default trees at: " .. defaultFile)

                if fileExists(defaultFile) then
                    print("TreePlantLoader: Found default treePlant.xml, loading...")
                    return originalLoadFromXMLFile(self, defaultFile)
                else
                    print("TreePlantLoader: No default treePlant.xml found")
                end
            end
        else
            print("TreePlantLoader: Could not get mod directory (g_currentMission not ready)")
        end

        return false
    end

    -- Check if the provided file exists
    if fileExists(xmlFilename) then
        -- Check if it has trees or is empty
        local xmlFile = loadXMLFile("checkTree", xmlFilename)
        if xmlFile ~= nil and xmlFile ~= 0 then
            local hasTree = hasXMLProperty(xmlFile, "treePlant.tree(0)")
            delete(xmlFile)

            if hasTree then
                print("TreePlantLoader: Savegame treePlant.xml has trees, loading normally")
                return originalLoadFromXMLFile(self, xmlFilename)
            else
                print("TreePlantLoader: Savegame treePlant.xml is empty, loading defaults instead")
                -- Load defaults instead
                if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.map ~= nil then
                    local modDir = g_currentMission.missionInfo.map.baseDirectory
                    if modDir ~= nil then
                        local defaultFile = modDir .. "defaultSavegame/treePlant.xml"
                        if fileExists(defaultFile) then
                            print("TreePlantLoader: Loading default trees from: " .. defaultFile)
                            return originalLoadFromXMLFile(self, defaultFile)
                        end
                    end
                end
            end
        end
    end

    -- Fall back to original behavior
    return originalLoadFromXMLFile(self, xmlFilename)
end

print("TreePlantLoader: Hooked TreePlantManager:loadFromXMLFile")
