    local MSG_CLASS = "ecobee"
    local DEBUG_MODE = true
    local taskHandle = -1
    local TASK_ERROR = 2
    local TASK_ERROR_PERM = -2
    local TASK_SUCCESS = 4
    local TASK_BUSY = 1
    local Client_ID

    -- constants
    local PLUGIN_VERSION = "2.02"
    local ECOBEE_SID = "urn:ecobee-com:serviceId:Ecobee1"
    local TEMP_SENSOR_SID = "urn:upnp-org:serviceId:TemperatureSensor1"
    local TEMP_SETPOINT_HEAT_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1_Heat"
    local TEMP_SETPOINT_COOL_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1_Cool"
    local TEMP_SETPOINT_SID = "urn:upnp-org:serviceId:TemperatureSetpoint1"
    local HUMIDITY_SENSOR_SID = "urn:micasaverde-com:serviceId:HumiditySensor1"
    local HVAC_FAN_SID = "urn:upnp-org:serviceId:HVAC_FanOperatingMode1"
    local HVAC_USER_SID = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1"
    local HVAC_STATE_SID = "urn:micasaverde-com:serviceId:HVAC_OperatingState1"
    local HA_DEVICE_SID = "urn:micasaverde-com:serviceId:HaDevice1"
    local SWITCH_POWER_SID = "urn:upnp-org:serviceId:SwitchPower1"
    local MCV_ENERGY_METERING_SID = "urn:micasaverde-com:serviceId:EnergyMetering1"
    local SECURITY_SENSOR_SID = "urn:micasaverde-com:serviceId:SecuritySensor1"
    local DEFAULT_POLL = 180
    local MIN_POLL = 180
    local SOON = "5" -- seconds

    local PARENT_DEVICE
    local syncDevices = false

    local json = require("dkjson")
    local https = require "ssl.https"
    local ltn12 = require "ltn12"

    local API_ROOT = '/1/'
    local COOL_OFF = 4000
    local HEAT_OFF = -5002
    local MAX_ID_LIST_LEN = 25
    local MAX_AUTH_TOKEN_FAILURES = 5
    local version = "2.0"

    local veraTemperatureScale = "C"

    local function getVeraTemperatureScale()
      local code, data = luup.inet.wget("http://localhost:3480/data_request?id=lu_sdata")
      if (code == 0) then
        data = json.decode(data)
      end
      veraTemperatureScale = ((code == 0) and (data ~= nil) and (data.temperature ~= nil)) and data.temperature or "C"
    end


    -- utility functions

    local function log(text, level)
      luup.log(MSG_CLASS .. ": " .. text, (level or 1))
    end

    local function debug(text)
      if (DEBUG_MODE) then
        log("debug: " .. text, 35)
      end
    end

    local function readVariableOrInit(lul_device, serviceId, name, defaultValue) 
      local var = luup.variable_get(serviceId, name, lul_device)
      if (var == nil) then
        var = defaultValue
        luup.variable_set(serviceId, name, var, lul_device)
      end
      return var
    end

    local function writeVariable(lul_device, serviceId, name, value) 
      luup.variable_set(serviceId, name, value, lul_device)
    end

    local function writeVariableIfChanged(lul_device, serviceId, name, value)
      local curValue = luup.variable_get(serviceId, name, lul_device)
      if value ~= curValue then
        writeVariable(lul_device, serviceId, name, value)
      end
      return value ~= curValue
    end

    local function findChild(deviceId, label)
      for k, v in pairs(luup.devices) do
        if (v.device_num_parent == deviceId and v.id == label) then
          return k
        end
      end
    end

    local function task(text, mode)
      local mode = mode or TASK_ERROR
      if (mode ~= TASK_SUCCESS) then
        log("task: " .. text, 50)
      end
      taskHandle = luup.task(text, (mode == TASK_ERROR_PERM) and TASK_ERROR or mode, MSG_CLASS, taskHandle)
      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "TSK", text)
    end


    -- child device altids
    local THERM_ID_PREFIX = "therm."
    local HUMID_ID_PREFIX = "humid."
    local HOUSE_ID_PREFIX = "house."
    local SENSOR_ID_PREFIX = "sensor."

    -- isolate the number after the "." but before an "_"
    local function getThermostatId(lul_device)
      local altid = luup.devices[lul_device].id
      return string.sub(altid, string.find(altid, "%d+"))
    end

    -- find the sibling device that is really the kind of device we are looking for
    -- defaults to finding the thermostat sibling if prefix not specified
    local function findSibling(lul_device, prefix)
      prefix = prefix or THERM_ID_PREFIX
      local id = getThermostatId(lul_device)
      local therm_id = prefix .. id
      for k,v in pairs(luup.devices) do
        if luup.devices[lul_device].device_num_parent == v.device_num_parent and v.id == therm_id then
          return k
        end
      end
    end

    local function round(value, precision)
      return (value >= 0) and
        (math.floor(value * precision + 0.5) / precision) or 
        (math.ceil(value * precision - 0.5) / precision)
    end

    local TemperaturePrecision = 1

    -- convert thermostat format (F*10) to local format (C or F)
    local function localizeTemp(temperature)
      temperature = temperature or -5002
      return (veraTemperatureScale == "F") and round(temperature/10, TemperaturePrecision) or
             round(((temperature/10 + 0.0) - 32.0) / 1.8, TemperaturePrecision)
    end

    -- convert local format (C or F) to thermostat format (F*10)
    local function delocalizeTemp(temperature)
      return (veraTemperatureScale == "F") and temperature*10 or
             round((((temperature + 0.0) * 1.8) + 32)*10, 1)
    end

    -- convert "2013-02-20 23:23:44" to number of seconds since 1/1/1970
    local function toSeconds(dateString, useLocal)
      useLocal = useLocal or false
      local year, month, day, hour, min, sec = string.match(dateString, "(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)")
      local offset = useLocal and 0 or (os.time() - os.time(os.date("!*t")))
      return os.time{year=year, month=month, day=day, hour=hour, min=min, sec=sec} + offset
    end

    -- find the event that is considered the current event and return it
    local function getCurrentEvent(events)
      if not events then return nil end
      for i=1,#events do
        if events[i].running then
          return events[i]
        end
      end
      return nil
    end

    -- the plugin defines the current climate as either the climate used for the current hold,
    -- or if there is no current hold, the current program's climate.  If there is a current hold
    -- but it's not based on a climate, then the current climate is the empty string ""
    local function getCurrentClimateRef(t)
      local climate = t.program and t.program.currentClimateRef
      local event = getCurrentEvent(t.events)
      if event then
        climate = event.holdClimateRef
      end
      return climate or ""
    end

    -- "Home" is defined as there being an active hold event with a holdClimateRef of "home", OR
    -- there being no current hold event but the current program's climate ref is "home"
    local function isHome(t)
      return getCurrentClimateRef(t) == "home" or getCurrentClimateRef(t) == "sleep" or
             (t.events and #t.events > 0 and t.events[1]["type"] == "switchOccupancy" and t.events[1].name == "occupied")
    end

    -- convert ecobee values to UPnP values
    local ECOBEE_TO_UPNP = {
      [ECOBEE_SID] = {
        ["thermostatRev"] = function(r) return r.thermostatRev end,
        ["runtimeRev"] = function(r) return r.runtimeRev end,
        ["equipmentStatus"] = function(r) return r.equipmentStatus or "unknown" end,
        ["quickSaveSetBack"] = function(t) return tostring(t.settings.quickSaveSetBack) end,
        ["quickSaveSetForward"] = function(t) return tostring(t.settings.quickSaveSetForward) end,
        ["holdType"] = function(t) return "indefinite" end, -- default value on device creation
        ["currentEventType"] = function(t)
          local event = getCurrentEvent(t.events)
          return (event and event["type"]) and event["type"] or "none"
        end,
        ["currentClimateRef"] = function(t) return getCurrentClimateRef(t) end,
        ["StreetAddress"] = function(t) return t.location.streetAddress end,
        ["City"] = function(t) return t.location.city end,
        ["ProvinceState"] = function(t) return t.location.provinceState end,
        ["Country"] = function(t) return t.location.country end,
        ["PostalCode"] = function(t) return t.location.postalCode end,
        ["PhoneNumber"] = function(t) return t.location.phoneNumber end,
        ["MapCoordinates"] = function(t) return t.location.mapCoordinates end,
        ["HumidityModeState"] = function(t)
          -- return "Humidifying", "Dehumidifying", "Idle" from list of humidifier, dehumidifier
          if (string.find(t.equipmentStatus, "dehumid"))    then return "Dehumidifying"
          elseif (string.find(t.equipmentStatus, "humid"))  then return "Humidifying"
          else return "Idle"
          end
        end
      },
      [SWITCH_POWER_SID] = {
        ["Status"] = function(t) return isHome(t) and "1" or "0" end
      },
      [TEMP_SENSOR_SID] = {
        ["Application"] = function() return "Room" end,
        ["CurrentTemperature"] = function(t, cap) return (not cap) and tostring(localizeTemp(t.runtime.actualTemperature)) or tostring(localizeTemp(tonumber(cap.value))) end
      },
      [TEMP_SETPOINT_HEAT_SID] = {
        ["Application"] = function() return "Heating" end,
        ["CurrentSetpoint"] = function(t) return tostring(localizeTemp(t.runtime.desiredHeat)) end
      },
      [TEMP_SETPOINT_COOL_SID] = {
        ["Application"] = function() return "Cooling" end,
        ["CurrentSetpoint"] = function(t) return tostring(localizeTemp(t.runtime.desiredCool)) end
      },
      [TEMP_SETPOINT_SID] = {
        ["Application"] = function() return "DualHeatingCooling" end,
        ["CurrentSetpoint"] = function(t)
          local desiredTemp = (t.settings.hvacMode == "heat") and t.runtime.desiredHeat or 
                              ((t.settings.hvacMode == "cool") and t.runtime.desiredCool or ((t.runtime.desiredHeat + t.runtime.desiredCool) / 2))
          return tostring(localizeTemp(desiredTemp))
        end
      },
      [HUMIDITY_SENSOR_SID] = {
        ["CurrentLevel"] = function(t, cap) return (not cap) and tostring(t.runtime.actualHumidity) or (cap.value == "unknown" and "0" or cap.value) end
      },
      [HVAC_FAN_SID] = {
        ["Mode"] = function(t)
          local fan = (t.events and #t.events > 0) and t.events[1].fan or nil
          -- TODO: add in "and t.events[1].running" above once it can be relied on
          
          -- if there is no current event, inspect the current climate
          if not fan and t.settings and t.program and t.program.climates then
            for i,v in ipairs(t.program.climates) do
              if v.climateRef == t.program.currentClimateRef then
                fan = t.settings.hvacMode == "cool" and v.coolFan or v.heatFan
                break
              end
            end
          end

          if fan == "auto" then return "Auto"
          elseif fan == "on" then return "ContinuousOn"
          else
            log("Unknown fan '" .. tostring(fan) .. "'.")
            return "Unknown"
          end
        end,
        ["FanStatus"] = function(t)
          return t.equipmentStatus and (string.find(t.equipmentStatus, "fan") and "On" or "Off") or "Unknown"
        end
      },
      [HVAC_USER_SID] = {
        ["ModeStatus"] = function(t)
          if     (t.settings.hvacMode == "heat")  then return "HeatOn"
          elseif (t.settings.hvacMode == "cool")  then return "CoolOn"
          elseif (t.settings.hvacMode == "auto")  then return "AutoChangeOver"
          elseif (t.settings.hvacMode == "off")   then return "Off"
          else return "InDeadBand"
          end
        end
      },
      [HVAC_STATE_SID] = {
        ["ModeState"] = function(t)
          -- return "Heating", "Cooling", "FanOnly", "Idle", "PendingHeat", "PendingCool", "Vent"
          -- from list of heatPump, compCool1, compCool2, auxHeat1, auxHeat2, auxHeat3, fan,
          --              humidifier, dehumidifier, ventilator, economizer, compHotWater, auxHotWater
          if     (t.equipmentStatus == "")                then return "Idle"
          elseif (t.equipmentStatus == "fan")             then return "FanOnly"
          elseif (string.find(t.equipmentStatus, "eat"))  then return "Heating"
          elseif (string.find(t.equipmentStatus, "ool"))  then return "Cooling"
          elseif (string.find(t.equipmentStatus, "vent")) then return "Vent"
          elseif (t.settings.hvacMode == "off")           then return "Off"
          else return ""
          end
        end
      },
      [HA_DEVICE_SID] = {
       ["LastUpdate"] = function(t) return tostring(toSeconds(t.runtime.lastModified)) end,
       ["CommFailure"] = function(r,cap) return (not cap) and (r.connected and "0" or "1") or (cap.value == "unknown" and "1" or "0") end,
       ["Commands"] = function(t)
         local commands = { "hvac_off", "hvac_auto", "hvac_cool",  "hvac_heat",
                            "fan_auto", "fan_on",    "hvac_state", "resume_program" }
         if t.runtime.desiredHeat ~= HEAT_OFF then
           commands[#commands + 1] = "heating_setpoint"
         end
         if t.runtime.desiredCool ~= COOL_OFF then
           commands[#commands + 1] = "cooling_setpoint"
         end
         return table.concat(commands, ",")
       end
      },
      [MCV_ENERGY_METERING_SID] = {
        ["UserSuppliedWattage"] = function(t) return "0,0,0" end
      },
      [SECURITY_SENSOR_SID] = {
        ["Tripped"] = function(t,cap) return (cap and cap.value == "true") and "1" or "0" end,
        ["LastTrip"] = function(t, cap) return "0" end,
        ["Armed"] = function(t, cap) return "0" end
      }
    }

    local function ecobeeToUpnp(serviceId, variableName, ...)
      return ECOBEE_TO_UPNP[serviceId][variableName](...)
    end

    local function ecobeeToUpnpParam(serviceId, variableName, ...)
      return serviceId .. "," .. variableName .. "=" .. ecobeeToUpnp(serviceId, variableName, ...)
    end

    local function writeVariableFromEcobee(lul_device, serviceId, name, ...)
      writeVariable(lul_device, serviceId, name, ecobeeToUpnp(serviceId, name, ...))
    end

    local function writeVariableFromEcobeeIfChanged(lul_device, serviceId, name, ...)
      return writeVariableIfChanged(lul_device, serviceId, name, ecobeeToUpnp(serviceId, name, ...))
    end

    -- convert UPnP values to ecobee values
    local UPNP_TO_ECOBEE = {
      [TEMP_SETPOINT_HEAT_SID] = {
        ["SetCurrentSetpoint"] = {
          ["NewCurrentSetpoint"] = function(lul_settings)
            return delocalizeTemp(lul_settings.NewCurrentSetpoint)
          end
        }
      },
      [TEMP_SETPOINT_COOL_SID] = {
        ["SetCurrentSetpoint"] = {
          ["NewCurrentSetpoint"] = function(lul_settings)
            return delocalizeTemp(lul_settings.NewCurrentSetpoint)
          end
        }
      },
      [TEMP_SETPOINT_SID] = {
        ["SetCurrentSetpoint"] = {
          ["NewCurrentSetpoint"] = function(lul_settings)
            return delocalizeTemp(lul_settings.NewCurrentSetpoint)
          end
        }
      },
      [HVAC_FAN_SID] = {
        ["SetMode"] = {
          ["NewMode"] = function(lul_settings)
            if (lul_settings.NewMode == "ContinuousOn") then return "on"
            elseif (lul_settings.NewMode == "Auto") then return "auto"
            end
          end
        }
      },
      [HVAC_USER_SID] = {
        ["SetModeTarget"] = {
          ["NewModeTarget"] = function(lul_settings)
            if     (lul_settings.NewModeTarget == "HeatOn")         then return "heat"
            elseif (lul_settings.NewModeTarget == "CoolOn")         then return "cool"
            elseif (lul_settings.NewModeTarget == "AutoChangeOver") then return "auto"
            elseif (lul_settings.NewModeTarget == "Off")            then return "off"
            elseif (lul_settings.NewModeTarget == "AuxHeatOn")      then return "auxHeatOnly"
            end
          end
        }
      }
    }

    local function upnpToEcobee(serviceId, actionName, variableName, lul_settings)
      return UPNP_TO_ECOBEE[serviceId][actionName][variableName](lul_settings)
    end

    local auth_token_failures = 0

    local function loadSession()
      local session = {}

      -- Config variables
      session.poll   = tonumber(readVariableOrInit(PARENT_DEVICE, ECOBEE_SID, "poll", tostring(DEFAULT_POLL)))
      session.poll   = session.poll or DEFAULT_POLL
      session.poll   = (session.poll < MIN_POLL) and MIN_POLL or session.poll 

      session.selectionType  = readVariableOrInit(PARENT_DEVICE, ECOBEE_SID, "selectionType", "registered")
      session.selectionMatch = readVariableOrInit(PARENT_DEVICE, ECOBEE_SID, "selectionMatch", "")
      session.scope = readVariableOrInit(PARENT_DEVICE, ECOBEE_SID, "scope", "smartWrite")

      -- Session variables
      session.auth_token = luup.variable_get(ECOBEE_SID, "auth_token", PARENT_DEVICE)
      if session.auth_token == "" then session.auth_token = nil end

      session.auth_token_failures = auth_token_failures

      session.access_token = luup.variable_get(ECOBEE_SID, "access_token", PARENT_DEVICE)
      if session.access_token == "" then session.access_token = nil end

      session.token_type = luup.variable_get(ECOBEE_SID, "token_type", PARENT_DEVICE)
      if session.token_type == "" then session.token_type = nil end

      session.refresh_token = luup.variable_get(ECOBEE_SID, "refresh_token", PARENT_DEVICE)
      if session.refresh_token == "" then session.refresh_token = nil end

      return session
    end

    local function saveSession(session)
      if session.error then
        log("Error: " .. tostring(session.error) .. ": " .. tostring(session.error_description))
	task("Error: " .. tostring(session.error) .. ": " .. tostring(session.error_description))
      end

      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "auth_token",    session.auth_token or "")
      auth_token_failures = session.auth_token_failures or 0
      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "access_token",  session.access_token or "")
      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "token_type",    session.token_type or "")
      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "refresh_token", session.refresh_token or "")

      local status = (session.access_token and session.access_token ~= "" and not session.error)
      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "status", status and "1" or "0")
    end

    -- wrapper ecobee API calls so saveSession is called after each API call
    local function getPin(session)
      local pin = reqPin(session)
      saveSession(session)
      return pin
    end
    
    local function getTokens(session)
      local access_token, token_type, refresh_token, scope = reqTokens(session, Client_ID)
      saveSession(session)
      return access_token, token_type, refresh_token, scope
    end

    local function getThermostatSummary(session, thermostatSummaryOptions)
      local revisions = reqThermostatSummary(session, thermostatSummaryOptions)
      saveSession(session)
      return revisions
    end

    local function getThermostats(session, thermostatsOptions)
      local thermostats = getThermostats(session, thermostatsOptions)
      saveSession(session)
      return thermostats
    end

    local function updateThermostats(session, thermostatsUpdateOptions)
      local success = requpdateThermostats(session, thermostatsUpdateOptions)
      saveSession(session)
      return success
    end

    local function getSelection(session, lul_device)
      return lul_device == PARENT_DEVICE and { selectionType = session.selectionType, selectionMatch = session.selectionMatch }
                                          or { selectionType = "thermostats", selectionMatch = getThermostatId(lul_device) }
    end

    local statusOutstanding = false
    local function getStatusSoon()
      if not statusOutstanding then
        statusOutstanding = true
        debug("Scheduling status poll in " .. SOON .. " seconds.")
        luup.call_timer("getStatus", 1, SOON, "", "")
      end
    end
    
    -- get status from ecobee
    
    function getStatus()
      -- debug("in getStatus()")

      statusOutstanding = false

      local session = loadSession()

      if not session.auth_token then
        task("Not yet authorized. Press 'Get PIN' once; wait for PIN; enter at ecobee.com.")
      else
        if not session.refresh_token then
          debug("About to getTokens...")
          getTokens(session)
        end

        if not session.refresh_token then
          log("Skipping this status update due to previous errors.")
          return
        end

        debug("Fetching revisions...")
        local revisions = getThermostatSummary(session, selectionObject(session.selectionType, session.selectionMatch, { equipmentStatus = true }))
        if not revisions then
          log("Unable to getThermostatSummary; skipping status update.")
          return
        end

        local count = 0
        for k,v in pairs(revisions) do count = count + 1 end
        writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "DisplayLabel", "Thermostats")
        writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "DisplayValue", tostring(count))

        -- first, see if Vera doesn't know the same thermostats, humidistats and houses as ecobee.com knows thermostats
        local newDevices = 0
        for id,revision in pairs(revisions) do
          if not findChild(PARENT_DEVICE, THERM_ID_PREFIX .. id) then
            newDevices = newDevices + 1
          end
          if not findChild(PARENT_DEVICE, HUMID_ID_PREFIX .. id) then
            newDevices = newDevices + 1
          end
          if not findChild(PARENT_DEVICE, HOUSE_ID_PREFIX .. id) then
            newDevices = newDevices + 1
          end
        end

        -- also check to see if Vera knows thermostats that are no longer reported by ecobee.com
        local oldDevices = 0
        for device_num, v in pairs(luup.devices) do
          if v.device_num_parent == PARENT_DEVICE then
            if not revisions[getThermostatId(device_num)] then
              oldDevices = oldDevices + 1
            end
          end
        end

        -- if the sets of devices are out of sync...
        if newDevices > 0 or oldDevices > 0 or syncDevices then
          syncDevices = false
          -- do a full thermostat fetch and create child devices
          log("Synchronizing devices with ecobee.com...")

          local includes = { settings=true, runtime=true, events=true, program=true, location=true, equipmentStatus=true, sensors=true }
          local options = selectionObject(session.selectionType, session.selectionMatch, includes)
          local thermostats = getThermostats(session, options)
          if thermostats then

            local ptr = luup.chdev.start(PARENT_DEVICE)

            for id,t in pairs(thermostats) do
              local name = t.name == "" and id or t.name
              local r = revisions[id]
              local altid = THERM_ID_PREFIX .. id
              luup.chdev.append(PARENT_DEVICE, ptr, altid, name, "urn:schemas-upnp-org:device:HVAC_ZoneThermostat:1",
                                "D_EcobeeThermostat1.xml", "",
                                ecobeeToUpnpParam(ECOBEE_SID, "thermostatRev", r) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "runtimeRev", r) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "equipmentStatus", r) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "quickSaveSetBack", t) .. 
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "quickSaveSetForward", t) .. 
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "holdType", t) .. 
                        "\n" .. ecobeeToUpnpParam(TEMP_SENSOR_SID, "CurrentTemperature", t) ..
                        "\n" .. ecobeeToUpnpParam(TEMP_SETPOINT_HEAT_SID, "CurrentSetpoint", t) ..
                        "\n" .. ecobeeToUpnpParam(TEMP_SETPOINT_COOL_SID, "CurrentSetpoint", t) ..
                        "\n" .. ecobeeToUpnpParam(TEMP_SETPOINT_SID, "CurrentSetpoint", t) ..
                        "\n" .. ecobeeToUpnpParam(HVAC_FAN_SID, "Mode", t) ..
                        "\n" .. ecobeeToUpnpParam(HVAC_FAN_SID, "FanStatus", t) ..
                        "\n" .. ecobeeToUpnpParam(HVAC_USER_SID, "ModeStatus", t) ..
                        "\n" .. ecobeeToUpnpParam(HVAC_STATE_SID, "ModeState", t) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "LastUpdate", t) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "CommFailure", r) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "Commands", t) ..
                        "\n" .. ecobeeToUpnpParam(MCV_ENERGY_METERING_SID, "UserSuppliedWattage", t)
                                , false, false)

              altid = HUMID_ID_PREFIX .. id
              luup.chdev.append(PARENT_DEVICE, ptr, altid, name, "urn:schemas-ecobee-com:device:EcobeeHumidistat:1",
                                "D_EcobeeHumidistat1.xml", "",
                                ecobeeToUpnpParam(HUMIDITY_SENSOR_SID, "CurrentLevel", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "HumidityModeState", t) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "LastUpdate", t) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "CommFailure", r)
                                , false, false)

              altid = HOUSE_ID_PREFIX .. id
              luup.chdev.append(PARENT_DEVICE, ptr, altid, name, "urn:schemas-ecobee-com:device:EcobeeHouse:1",
                                "D_EcobeeHouse1.xml", "",
                                ecobeeToUpnpParam(SWITCH_POWER_SID, "Status", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "StreetAddress", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "City", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "ProvinceState", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "Country", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "PostalCode", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "PhoneNumber", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "MapCoordinates", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "currentEventType", t) ..
                        "\n" .. ecobeeToUpnpParam(ECOBEE_SID, "currentClimateRef", t) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "LastUpdate", t) ..
                        "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "CommFailure", r)
                                , false, false)

              -- loop through any remote sensors we received for this thermostat
              if t.remoteSensors then
                for irs,rs in pairs(t.remoteSensors) do
                  for icap,cap in pairs(rs.capability) do
                    altid = SENSOR_ID_PREFIX .. id .. "_" .. rs.id .. "_" .. cap.id
                    if cap.type == "humidity" then
                      luup.chdev.append(PARENT_DEVICE, ptr, altid, rs.name, "urn:schemas-micasaverde-com:device:HumiditySensor:1",
                                        "D_HumiditySensor1.xml", "",
                                        ecobeeToUpnpParam(HUMIDITY_SENSOR_SID, "CurrentLevel", t, cap) ..
                                "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "LastUpdate", t) ..
                                "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "CommFailure", r, cap)
                                        , false, false)
                    elseif cap.type == "temperature" then
                      luup.chdev.append(PARENT_DEVICE, ptr, altid, rs.name, "urn:schemas-micasaverde-com:device:TemperatureSensor:1",
                                        "D_TemperatureSensor1.xml", "",
                                        ecobeeToUpnpParam(TEMP_SENSOR_SID, "CurrentTemperature", t, cap) ..
                                "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "LastUpdate", t) ..
                                "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "CommFailure", r, cap)
                                        , false, false)
                    elseif cap.type == "occupancy" then
                      luup.chdev.append(PARENT_DEVICE, ptr, altid, rs.name, "urn:schemas-micasaverde-com:device:MotionSensor:1",
                                        "D_MotionSensor1.xml", "",
                                        ecobeeToUpnpParam(SECURITY_SENSOR_SID, "Tripped", t, cap) ..
                                "\n" .. ecobeeToUpnpParam(SECURITY_SENSOR_SID, "LastTrip", t, cap) ..
                                "\n" .. ecobeeToUpnpParam(SECURITY_SENSOR_SID, "Armed", t, cap) ..
                                "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "LastUpdate", t) ..
                                "\n" .. ecobeeToUpnpParam(HA_DEVICE_SID, "CommFailure", r, cap)
                                        , false, false)
                    end
                  end
                end
              end
            end

            luup.chdev.sync(PARENT_DEVICE, ptr)
            log("Updated children device(s); awaiting restart...")
            return
          end

        else

          -- see which thermostats have changed settings or runtime values, equipment status or connected state
          local changed = {}
          for id,revision in pairs(revisions) do
            local child = findChild(PARENT_DEVICE, THERM_ID_PREFIX .. id)
            if not child then
              log("Failed to find device for thermostat " .. id)
            else
              if (revision.thermostatRev ~= luup.variable_get(ECOBEE_SID, "thermostatRev", child)) or
                 (revision.runtimeRev ~= luup.variable_get(ECOBEE_SID, "runtimeRev", child)) or 
                 (revision.equipmentStatus ~= luup.variable_get(ECOBEE_SID, "equipmentStatus", child)) or
                 (revision.connected ~= (luup.variable_get(HA_DEVICE_SID, "CommFailure", child) == "0")) then
                changed[#changed + 1] = id
              end
            end
          end

          debug(tostring(#changed) .. " update(s) found from ecobee.com.")

          if #changed > 0 then
            -- just fetch the changed thermostats from ecobee.com
            local includes = { settings=true, runtime=true, events=true, program=true, equipmentStatus=true, sensors=true }
            local thermostats = getThermostats(session, selectionObject("thermostats", changed, includes))
            if thermostats then
              for id,t in pairs(thermostats) do
                local r = revisions[id]

                local altid = THERM_ID_PREFIX .. id
                local child = findChild(PARENT_DEVICE, altid)
                if not child then
                  log("failed to find device for thermostat " .. altid)
                else
                  -- make sure this device has category_num=5
                  if luup.attr_get("category_num", child) ~= "5" then
                    luup.attr_set("category_num", "5", child)
                  end
                  if luup.attr_get("manufacturer", child) ~= "ecobee" then
                    luup.attr_set("manufacturer", "ecobee", child)
                  end
                  if luup.attr_get("model", child) ~= t.modelNumber then
                    luup.attr_set("model", t.modelNumber, child)
                  end
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "thermostatRev", r)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "runtimeRev", r)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "equipmentStatus", r)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "quickSaveSetBack", t)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "quickSaveSetForward", t)
                  readVariableOrInit(child, ECOBEE_SID, "holdType", "indefinite") -- create device variable if doesn't exist
                  writeVariableFromEcobeeIfChanged(child, TEMP_SENSOR_SID, "CurrentTemperature", t)
                  writeVariableFromEcobeeIfChanged(child, TEMP_SETPOINT_HEAT_SID, "CurrentSetpoint", t)
                  writeVariableFromEcobeeIfChanged(child, TEMP_SETPOINT_COOL_SID, "CurrentSetpoint", t)
                  writeVariableFromEcobeeIfChanged(child, TEMP_SETPOINT_SID, "CurrentSetpoint", t)
                  writeVariableFromEcobeeIfChanged(child, HVAC_FAN_SID, "Mode", t)
                  writeVariableFromEcobeeIfChanged(child, HVAC_FAN_SID, "FanStatus", t)
                  writeVariableFromEcobeeIfChanged(child, HVAC_USER_SID, "ModeStatus", t)
                  writeVariableFromEcobeeIfChanged(child, HVAC_STATE_SID, "ModeState", t)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "LastUpdate", t)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "CommFailure", r)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "Commands", t)
                end

                altid = HUMID_ID_PREFIX .. id
                child = findChild(PARENT_DEVICE, altid)
                if not child then
                  log("failed to find device for humidistat " .. altid)
                else
                  -- make sure this device has category_num=16
                  if luup.attr_get("category_num", child) ~= "16" then
                    luup.attr_set("category_num", "16", child)
                  end
                  writeVariableFromEcobeeIfChanged(child, HUMIDITY_SENSOR_SID, "CurrentLevel", t)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "HumidityModeState", t)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "LastUpdate", t)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "CommFailure", r)
                end
                  
                altid = HOUSE_ID_PREFIX .. id
                child = findChild(PARENT_DEVICE, altid)
                if not child then
                  log("failed to find device for house " .. altid)
                else
                  -- make sure this device has category_num=3
                  if luup.attr_get("category_num", child) ~= "3" then
                    luup.attr_set("category_num", "3", child)
                  end
                  writeVariableFromEcobeeIfChanged(child, SWITCH_POWER_SID, "Status", t)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "currentEventType", t)
                  writeVariableFromEcobeeIfChanged(child, ECOBEE_SID, "currentClimateRef", t)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "LastUpdate", t)
                  writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "CommFailure", r)
                end

                -- loop through any remote sensors we received for this thermostat
                if t.remoteSensors then
                  for irs,rs in pairs(t.remoteSensors) do
                    for icap,cap in pairs(rs.capability) do
                      altid = SENSOR_ID_PREFIX .. id .. "_" .. rs.id .. "_" .. cap.id
                      local child = findChild(PARENT_DEVICE, altid)
                      if not child then
                        log("failed to find device for sensor " .. altid .. "; will sync on next poll")
                        syncDevices = true
                      else
                        if cap.type == "humidity" then
                          -- make sure this device has category_num=16 (Humidity Sensor)
                          if luup.attr_get("category_num", child) ~= "16" then
                            luup.attr_set("category_num", "16", child)
                          end
                          writeVariableFromEcobeeIfChanged(child, HUMIDITY_SENSOR_SID, "CurrentLevel", t, cap)
                          writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "LastUpdate", t)
                          writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "CommFailure", r, cap)
                        elseif cap.type == "temperature" then
                          -- make sure this device has category_num=17 (Temperature Sensor)
                          if luup.attr_get("category_num", child) ~= "17" then
                            luup.attr_set("category_num", "17", child)
                          end
                          writeVariableFromEcobeeIfChanged(child, TEMP_SENSOR_SID, "CurrentTemperature", t, cap)
                          writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "LastUpdate", t)
                          writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "CommFailure", r, cap)
                        elseif cap.type == "occupancy" then
                          -- make sure this device has category_num=4 (Security Sensor)
                          if luup.attr_get("category_num", child) ~= "4" then
                            luup.attr_set("category_num", "4", child)
                          end
                          -- make sure this device has subcategory_num=3 (Motion Sensor)
                          if (luup.attr_get("subcategory_num", child) ~= "3") then
                            luup.attr_set("subcategory_num", "3", child)
                          end
                          -- set LastTrip to now if Tripped is transitioning from "0" to "1"
                          local newTripped = ecobeeToUpnp(SECURITY_SENSOR_SID, "Tripped", t, cap)
                          if newTripped == "1" and luup.variable_get(SECURITY_SENSOR_SID, "Tripped", child) ~= "1" then
                            writeVariableIfChanged(child, SECURITY_SENSOR_SID, "LastTrip", tostring(os.time()))
                          end
                          writeVariableIfChanged(child, SECURITY_SENSOR_SID, "Tripped", newTripped)
                          writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "LastUpdate", t)
                          writeVariableFromEcobeeIfChanged(child, HA_DEVICE_SID, "CommFailure", r, cap)
                        end
                      end
                    end
                  end
                end -- if t.remoteSensors
              end  -- for
            end  -- if thermostats
          end  -- if #changed > 0

        end -- if new or old (out of sync)
      end -- session state
    end -- getStatus()

    -- Functions that Change Thermostat State

    local function setHold(session, selection, lul_device, func)
      debug("in setHold()")

      lul_device = findSibling(lul_device)
      if not lul_device then
        task("Unable to find sibling thermostat device; aborting setHold.")
        return false
      end

      -- determine which type of hold to set
      func.params.holdType = readVariableOrInit(lul_device, ECOBEE_SID, "holdType", "indefinite")

      -- if selection is nil, we will make our own.
      selection = selection or getSelection(session, lul_device)

      if not func.params.holdClimateRef then

        -- if func.params.coolHoldTemp, func.params.heatHoldTemp or func.params.fan are nil,
        -- use the current device's state to supply the missing values.
        if not func.params.heatHoldTemp then
          local heatSetpoint = luup.variable_get(TEMP_SETPOINT_HEAT_SID, "CurrentSetpoint", lul_device)
          func.params.heatHoldTemp = heatSetpoint and upnpToEcobee(TEMP_SETPOINT_HEAT_SID, "SetCurrentSetpoint",
                                                       "NewCurrentSetpoint", { NewCurrentSetpoint = heatSetpoint })
                                                   or HEAT_OFF
        end
        
        if not func.params.coolHoldTemp then
          local coolSetpoint = luup.variable_get(TEMP_SETPOINT_COOL_SID, "CurrentSetpoint", lul_device)
          func.params.coolHoldTemp = coolSetpoint and upnpToEcobee(TEMP_SETPOINT_COOL_SID, "SetCurrentSetpoint",
                                                       "NewCurrentSetpoint", { NewCurrentSetpoint = coolSetpoint })
                                                   or COOL_OFF
        end

        if not func.params.fan then
          local fan = luup.variable_get(HVAC_FAN_SID, "Mode", lul_device)
          func.params.fan = fan and upnpToEcobee(HVAC_FAN_SID, "SetMode", "NewMode", { NewMode=fan }) or "auto"
        end
      end

      local success = updateThermostats(session, thermostatsUpdateOptions(selection, { func }))
      if success then getStatusSoon() end
      return success
    end

    local function setClimateHold(session, selection, lul_device, holdClimateRef)
      local func = setHoldFunction()
      func.params.holdClimateRef = holdClimateRef
      return setHold(session, selection, lul_device, func)
    end

    -- "away" function for binary switch device against Si thermostats
    -- want to use a real quickSave event but must use this for now.
    local function quickSave(session, selection, lul_device)

      local heatSetpoint = luup.variable_get(TEMP_SETPOINT_HEAT_SID, "CurrentSetpoint", lul_device)
      heatSetpoint = tonumber(heatSetpoint)
      local heatHoldTemp = (not heatSetpoint) and HEAT_OFF or
                             upnpToEcobee(TEMP_SETPOINT_HEAT_SID, "SetCurrentSetpoint",
                                          "NewCurrentSetpoint", { NewCurrentSetpoint = heatSetpoint })
      local coolSetpoint = luup.variable_get(TEMP_SETPOINT_COOL_SID, "CurrentSetpoint", lul_device)
      coolSetpoint = tonumber(coolSetpoint)
      local coolHoldTemp = (not coolSetpoint) and COOL_OFF or
                             upnpToEcobee(TEMP_SETPOINT_COOL_SID, "SetCurrentSetpoint",
                                          "NewCurrentSetpoint", { NewCurrentSetpoint = coolSetpoint })
      local quickSaveSetBack  = luup.variable_get(ECOBEE_SID, "quickSaveSetBack", lul_device)
      quickSaveSetBack = tonumber(quickSaveSetBack) or 40 -- TODO
      local quickSaveSetForward = luup.variable_get(ECOBEE_SID, "quickSaveSetForward", lul_device)
      quickSaveSetForward = tonumber(quickSaveSetForward) or 40 -- TODO

      local func = setHoldFunction()
      func.params.coolRelativeTemp = quickSaveSetForward
      func.params.heatRelativeTemp = quickSaveSetBack
      func.params.isTemperatureRelative = false
      func.params.coolHoldTemp = (coolHoldTemp == COOL_OFF) and coolHoldTemp or coolHoldTemp + quickSaveSetForward
      func.params.heatHoldTemp = (heatHoldTemp == HEAT_OFF) and heatHoldTemp or heatHoldTemp - quickSaveSetBack
      func.params.isTemperatureAbsolute = true
      return setHold(session, selection, lul_device, func)
    end

    -- "away" function for binary switch device against EMS thermostats
    local function setOccupied(session, selection, lul_device, occupied)
      local success = updateThermostats(session, thermostatsUpdateOptions(selection, { setOccupiedFunction(occupied, "indefinite") }))
      if success then getStatusSoon() end
      return success
    end

    -- "home" function for all thermostats
    local function resumeProgram(session, selection, calls)
      calls = calls or 1
      local functions = {}
      for i = 1,calls do
        functions[#functions + 1] = resumeProgramFunction()
      end
      local success = updateThermostats(session, thermostatsUpdateOptions(selection, functions))
      if success then getStatusSoon() end
      return success
    end

    local function isEmsThermostat(lul_device)
      local model = luup.attr_get("model", lul_device)
      return model and string.find(model, "Ems") ~= nil
    end

    -- setAway will set the thermostat into "away" mode.
    -- For non-EMS thermostats, Away -> setClimateHold to "home" or "away"
    -- For EMS thermostats, Away -> setOccupied occupied=false; and Home -> resumeProgram x3.
    -- The home/away state is calculated based on whether one of these holds is the currently
    -- running event.

    local function setAway(session, lul_device, away)
      debug("in setAway()")

      lul_device = findSibling(lul_device)
      if not lul_device then
        task("Unable to find sibling thermostat device; aborting setAway.")
        return false
      end

      local selection = getSelection(session, lul_device)

      if isEmsThermostat(lul_device) then
        return away and setOccupied(session, selection, lul_device, false) or resumeProgram(session, selection, 3)
      else
        return setClimateHold(session, selection, lul_device, away and "away" or "home")
      end
    end

    function poll_ecobee()
      -- debug("in poll_ecobee()")
     task("Connected!", TASK_SUCCESS)
      getStatus()
      
      -- set up the next poll
      local poll = tonumber(readVariableOrInit(PARENT_DEVICE, ECOBEE_SID, "poll", tostring(DEFAULT_POLL))) or DEFAULT_POLL
      if (poll < MIN_POLL) then poll = MIN_POLL end 
      poll = tostring(poll)
      writeVariableIfChanged(PARENT_DEVICE, ECOBEE_SID, "poll", poll)
      debug("polling device " .. PARENT_DEVICE .. " again in " .. poll .. " seconds")
      luup.call_timer("poll_ecobee", 1, poll, "", "")
    end

--[[
URL encoding (from Roberto Ierusalimschy's book "Programming in Lua" 2nd ed.)
]]--
local function escape(s)
  s = string.gsub(s, "[&=+%%%c]", function(c) return string.format("%%%02X", string.byte(c)) end)
  s = string.gsub(s, " ", "+")
  return s
end

local function stringify(t)
  local b = {}
  for k,v in pairs(t) do
    b[#b + 1] = (k .. "=" .. escape(v))
  end
  return table.concat(b, "&")
end

--[[

All calls below accept as their first argument a 'session' table containing these possible values:

* api_key
* scope
* auth_token
* access_token
* token_type
* refresh_token
* http_status
* error
* error_description

]]--

--[[
Generic request code handles get and post requests
Must specify options.url and dataString

Returns the possibly JSON-parsed table or string (or nil)
--]]
local function makeRequest(session, options, dataString)
  options.host = "api.ecobee.com"
  options.port = "443"
  local res = {}
  options.sink = ltn12.sink.table(res)
  options.method = options.method or "GET"
  options.headers = options.headers or {}
  options.headers["User-Agent"] = "ecobee-lua-api/" .. version
  options.headers["Content-Type"] = options.headers["Content-Type"] or "application/json;charset=UTF-8"
  options.protocol = "tlsv1_2"
  local errmsg

  if options.method == "POST" then
    options.headers["Content-Length"] = string.len(dataString)
    options.source = ltn12.source.string(dataString)
  else
    options.url = options.url .. "?" .. dataString
  end

  if session.log then
    session.log:write(">>> ", os.date(), "\n")
    for k,v in pairs(options.headers) do session.log:write(k, " ", v, "\n") end
    session.log:write(os.date(), " >>> ", options.method, " ", options.url, "\n")
    if options.method == "POST" then
      session.log:write(dataString, "\n")
    end
  end

  local one, code, headers, errmsg = https.request(options)

  res = table.concat(res)

  if session.log then
    session.log:write("<<< ", tostring(code), " ", tostring(errmsg), "\n")
    session.log:write(tostring(res), "\n")
    session.log:flush()
  end

  if options.headers.Accept == 'application/json' then
    local nc, parsed
    parsed, nc, errmsg = json.decode(res)
    if parsed then res = parsed end
  end

  -- extract the most specific error information and put it in the session
  if code ~= 200 then
    if type(res) == "table" then
      if res.status and res.status.code then
        session.error = tostring(res.status.code)
        session.error_description = res.status.message
      else
        session.error = res.error
        session.error_description = res.error_description or res.error_descripton
      end
    else
      session.error = tostring(code)
      session.error_description = errmsg
    end
  else
    session.error = nil
    session.error_description = nil
    return res
  end
end

--[[
Get a new pin for an application.

Expects these values on call:
* session.scope
* session.auth_token_failures = 0

Returns ecobeePin and sets these values on success:
* session.auth_token
]]--
function reqPin(session)
  local options = { url = "/authorize", headers = { Accept = "application/json" } }
  local data = { response_type = "ecobeePin", scope = session.scope, client_id = Client_ID }
  local res = makeRequest(session, options, stringify(data))
        
  if res and res.ecobeePin and res.code then
    session.auth_token = res.code
    session.auth_token_failures = 0
    session.access_token = nil
    session.token_type = nil
    session.refresh_token = nil
    return res.ecobeePin
  end
end

--[[
Use an auth_token to get a new set of tokens from the server.

Expects these values on call:
* session.auth_token

Sets and returns these values on success:
* session.access_token
* session.token_type
* session.refresh_token
* session.scope
]]--
function reqTokens(session)
  local options = { url = "/token", method = "POST",
                    headers = { Accept = "application/json", ["Content-Type"] = "application/x-www-form-urlencoded" } }
  local data = { grant_type = "ecobeePin", code = session.auth_token, client_id = Client_ID }
  local res = makeRequest(session, options, stringify(data))
  
  if res and res.access_token and res.token_type and res.refresh_token and res.scope then
    session.access_token  = res.access_token
    session.token_type    = res.token_type
    session.refresh_token = res.refresh_token
    session.scope         = res.scope
    return session.access_token, session.token_type, session.refresh_token, session.scope
  end
end

--[[
Use a refresh token to get a new set of tokens from the server.

Expects these values on call:
* session.refresh_token

Sets and returns these values on success:
* session.access_token
* session.token_type
* session.refresh_token
* session.scope
]]--
local function refreshTokens(session)
  local options = { url = "/token", method = "POST",
                    headers = { Accept = "application/json", ["Content-Type"] = "application/x-www-form-urlencoded" } }
  local data = { grant_type = "refresh_token", code = session.refresh_token, client_id = Client_ID }
  local res = makeRequest(session, options, stringify(data))

  -- if the API failed with an "invalid_client" or "invalid_grant" error after MAX_AUTH_TOKEN_FAILURES attempts, 
  -- then we have a rubbish auth_token or refresh_token and must discard the auth_token and force the user to get a new PIN
  if session.error == "invalid_client" or session.error == "invalid_grant" then
    session.auth_token_failures = (type(session.auth_token_failures) == "number") and (session.auth_token_failures + 1) or 1
    if session.auth_token_failures >= MAX_AUTH_TOKEN_FAILURES then
      session.auth_token = nil
      session.auth_token_failures = 0
    end
  end

  if res and res.access_token and res.token_type and res.refresh_token and res.scope then
    session.access_token  = res.access_token
    session.token_type    = res.token_type
    session.refresh_token = res.refresh_token
    session.scope         = res.scope
    task("Token refresh success!")
    return session.access_token, session.token_type, session.refresh_token, session.scope
  end
end

local ID_PAGE_SIZE = 25

--[[
Get the summary for the thermostats associated with this account.
All options are passed in the thermostatSummaryOptions table.

Expects these values on call:
* session.access_token
* session.token_type
(If it is to be retried if the access_token expired:)
* session.refresh_token

Returns these values on success:
* revisions table
]]--
function reqThermostatSummary(session, thermostatSummaryOptions, revisions)

  thermostatSummaryOptions = thermostatSummaryOptions or selectionObject("registered", "")

  if type(thermostatSummaryOptions.selection.selectionMatch) == "table" then

    -- chunk the thermostat IDs into batches of 25 by calling ourselves
    -- recursively but passing stringified chunks of IDs

    local ids = thermostatSummaryOptions.selection.selectionMatch
    revisions = revisions or {}
    for i=1,#ids,ID_PAGE_SIZE do
      j = math.min(#ids, (i+ID_PAGE_SIZE)-1)
      thermostatSummaryOptions.selection.selectionMatch = table.concat(ids, ",", i, j)
      if not reqThermostatSummary(session, thermostatSummaryOptions, revisions) then
        revisions = nil
        break
      end
    end
    thermostatSummaryOptions.selection.selectionMatch = ids
    return revisions

  else

    local jsonOptions = json.encode(thermostatSummaryOptions)
    local options = { url = API_ROOT .. "thermostatSummary", method = "GET",
                      headers = { Accept = "application/json", Authorization = session.token_type .. ' ' .. session.access_token } }

    local res = makeRequest(session, options, stringify{ json = jsonOptions, token = session.access_token })

    -- try again if the access_token expired
    if session.error == "14" and session.refresh_token and refreshTokens(session) then
      options = { url = API_ROOT .. "thermostatSummary", method = "GET",
                  headers = { Accept = "application/json", Authorization = session.token_type .. ' ' .. session.access_token } }
      res = makeRequest(session, options, stringify{ json = jsonOptions, token = session.access_token })
    end

    if not session.error and res.revisionList then
      -- replace colon-separated lists with table of tables to hide formatting from API user
      revisions = revisions or {}
      for i,v in ipairs(res.revisionList) do
        local identifier,name,connected,thermostatRev,alertsRev,runtimeRev = string.match(v, "(.-):(.-):(.-):(.-):(.-):(.-)$")
        revisions[identifier] = { name = name, connected = (connected == "true"),
                                  thermostatRev = thermostatRev, alertsRev = alertsRev, runtimeRev = runtimeRev }
      end
      -- if user requested equipmentStatus in the summary, parse it and add a member to revisions table
      if res.statusList then
        for i,v in ipairs(res.statusList) do
          local identifier,equipmentStatus = string.match(v, "(.-):(.-)$")
          if revisions[identifier] then
            revisions[identifier].equipmentStatus = equipmentStatus
          end
        end
      end

      return revisions
    end

  end
end

--[[
Gets thermostats defined by the thermostatsOptions object.

Expects these values on call:
* session.access_token
* session.token_type
(If it is to be retried if the access_token expired:)
* session.refresh_token

Returns these values on success:
* thermostats table
]]--
function getThermostats(session, thermostatsOptions, thermostats)

  if type(thermostatsOptions.selection.selectionMatch) == "table" then

    -- chunk the thermostat IDs into batches of 25 by calling ourselves
    -- recursively but passing stringified chunks of IDs

    local ids = thermostatsOptions.selection.selectionMatch
    thermostats = thermostats or {}
    for i=1,#ids,ID_PAGE_SIZE do
      j = math.min(#ids, (i+ID_PAGE_SIZE)-1)
      thermostatsOptions.selection.selectionMatch = table.concat(ids, ",", i, j)
      if not getThermostats(session, thermostatsOptions, thermostats) then
        thermostats = nil
        break
      end
    end
    thermostatsOptions.selection.selectionMatch = ids
    return thermostats

  else

    local page = 0
    local totalPages = 1

    repeat
      page = page + 1

      if page > 1 then
        thermostatsOptions.page = { page = page }
      end

      local jsonOptions = json.encode(thermostatsOptions)

      local options = { url = API_ROOT .. 'thermostat', method = "GET",
                        headers = { Accept = "application/json", Authorization = session.token_type .. ' ' .. session.access_token } }

      local res = makeRequest(session, options, stringify{ json = jsonOptions, token = session.access_token })

      -- try again if the access_token expired
      if session.error == "14" and session.refresh_token and refreshTokens(session) then
        options = { url = API_ROOT .. 'thermostat', method = "GET",
                    headers = { Accept = "application/json", Authorization = session.token_type .. ' ' .. session.access_token } }
        res = makeRequest(session, options, stringify{ json = jsonOptions, token = session.access_token })
      end

      if not session.error and res.thermostatList then
        thermostats = thermostats or {}
        for i,v in ipairs(res.thermostatList) do
          thermostats[v.identifier] = v
        end
        if res.page and res.page.totalPages then
          totalPages = res.page.totalPages
        end
      else
        thermostats = nil
        break
      end
    until page >= totalPages

    thermostatsOptions.page = nil
    return thermostats

  end
end

--[[
Update thermostats based on the thermostatsUpdateOptions object
Many common update actions have an associated function which are passed in an array
so that multiple updates can be completed at one time. 
Updates are completed in the order they appear in the functions array.

Expects these values on call:
* session.access_token
* session.token_type
(If it is to be retried if the access_token expired:)
* session.refresh_token

Returns these values on success:
* true if no error
]]--
function requpdateThermostats(session, thermostatsUpdateOptions)

  local options = { url = API_ROOT .. "thermostat?format=json",
                    method = "POST",
                    headers = { Accept = "application/json",
                                Authorization = session.token_type .. " " .. session.access_token,
                                ["Content-Type"] = "application/json" } }

  local body = json.encode(thermostatsUpdateOptions)
  local res = makeRequest(session, options, body)
  
  -- try again if the access_token expired
  if session.error == "14" and session.refresh_token and refreshTokens(session) then
    options.url = API_ROOT .. "thermostat?format=json"
    options.headers.Authorization = session.token_type .. " " .. session.access_token
    res = makeRequest(session, options, body)
  end

  return not session.error
end

-- convenience functions

local THERM_OPTIONS = {
  runtime = "includeRuntime",
  extendedRuntime = "includeExtendedRuntime",
  electricity = "includeElectricity",
  settings = "includeSettings",
  location = "includeLocation",
  program = "includeProgram",
  events = "includeEvents",
  devices = "includeDevice",
  technician = "includeTechnician",
  utility = "includeUtility",
  management = "includeManagement",
  alerts = "includeAlerts",
  weather = "includeWeather",
  houseDetails = "includeHouseDetails",
  oemCfg = "includeOemCfg",
  equipmentStatus = "includeEquipmentStatus",
  notificationSettings = "includeNotificationSettings",
  privacy = "includePrivacy",
  sensors = "includeSensors"
}

--[[
Default options for getThermostats function when using includes

selectionMatch can be a table of thermostat IDs, and it will be converted to
a comma-separated list right before transmission
]]--
function selectionObject(selectionType, selectionMatch, includes)

  local options = { selection = { selectionType=selectionType, selectionMatch=selectionMatch } }

  if includes then
    for k,v in pairs(includes) do
      options.selection[ THERM_OPTIONS[k] ] = v
    end
  end

  return options
end

-- get the hierarchy for EMS thermostats based on the node passed in
-- default node is the root level. EMS Only.
function managementSet(node)
  return selectionObject("managementSet", node or "/")
end

--[[
Default options for getThermostats function

function thermostatsOptions(thermostat_ids,
                            includeEvents,
                            includeProgram,
                            includeSettings,
                            includeRuntime,
                            includeAlerts,
                            includeWeather)

  if type(thermostat_ids) == "table" then
    thermostat_ids = table.concat(thermostat_ids, ",")
  end

  includeEvents   = includeEvents or true
  includeProgram  = includeProgram or true
  includeSettings = includeSettings or true
  includeRuntime  = includeRuntime or true
  includeAlerts   = includeAlerts or false
  includeWeather  = includeWeather or false

  return { selection = { 
    selectionType   = "thermostats",
    selectionMatch  = thermostat_ids,
    includeEvents   = includeEvents,
    includeProgram  = includeProgram,
    includeSettings = includeSettings,
    includeRuntime  = includeRuntime,
    includeAlerts   = includeAlerts,
    includeWeather  = includeWeather } }
end
]]--

--[[
Update options that control how the thermostats update call behaves
]]--
function thermostatsUpdateOptions(selection, functions, thermostat)
  return { selection = selection, functions = functions, thermostat = thermostat }
end

function createVacationFunction(coolHoldTemp, heatHoldTemp)
  return { ["type"] = "createVacation",
           params = { coolHoldTemp=coolHoldTemp, heatHoldTemp=heatHoldTemp } }
end

-- Function passed to the updateThermostats call to resume a program.
function resumeProgramFunction()
  return { ["type"] = "resumeProgram" }
end

-- Function passed to the updateThermostats call to send a message to the thermostat
function sendMessageFunction(text)
  return { ["type"]  = "sendMessage",
           params = { text = text } }
end

-- Function passed to the updateThermostats call to acknowledge an alert
-- Values for acknowledge_type: accept, decline, defer, unacknowledged.
function acknowledgeFunction(thermostat_id, acknowledge_ref, acknowledge_type, remind_later)
  return { ["type"] = "acknowledge",
           params = { thermostatIdentifier = thermostat_id,
                      ackRef = acknowledge_ref,
                      ackType = acknowledge_type,
                      remindMeLater = remind_later } }
end

-- Function passed to the updateThermostats set the occupied state of the thermostat
-- EMS only.
-- hold_type valid values: dateTime, nextTransition, indefinite, holdHours
function setOccupiedFunction(is_occupied, hold_type)
  return { ["type"] = "setOccupied",
           params = { occupied = is_occupied,
                      holdType = hold_type } }
end

-- Function passed to the thermostatsUpdate call to set a temperature hold. Need to pass both
-- temperature params.
-- holdType valid values: dateTime, nextTransition, indefinite, holdHours
function setHoldFunction(coolHoldTemp, heatHoldTemp, holdType, holdHours)
  return { ["type"] = "setHold",
           params = { coolHoldTemp = coolHoldTemp, heatHoldTemp = heatHoldTemp,
                      holdType = holdType, holdHours = holdHours } }
end

-- Object that represents a climate.
function climateObject(climate_data)
	return { name = climate_data.name,
           climateRef = climate_data.climateRef,
           isOccupied = climate_data.isOccupied,
           coolFan = climate_data.coolFan,
           heatFan = climate_data.heatFan,
           vent = climate_data.vent,
           ventilatorMinOnTime = climate_data.ventilatorMinOnTime,
           owner = climate_data.owner,
           ["type"] = climate_data["type"],
           coolTemp = climate_data.coolTemp,
           heatTemp = climate_data.heatTemp }
end


    function init(lul_device)
      log("plugin version " .. PLUGIN_VERSION .. " starting up...", 50)

      PARENT_DEVICE = lul_device
      Client_ID = luup.variable_get(ECOBEE_SID, "API_Key", lul_device)
      TemperaturePrecision = tonumber(readVariableOrInit(PARENT_DEVICE, ECOBEE_SID, "TemperaturePrecision", "1"))
      TemperaturePrecision = TemperaturePrecision or 1
      if TemperaturePrecision < 1 or TemperaturePrecision > 1000 then
        TemperaturePrecision = 1
      end

      getVeraTemperatureScale()

      -- perform the first poll 5-10 seconds from now

      local soon = tonumber(SOON)
      soon = soon + math.random(0,soon)

      debug("polling ecobee.com " .. PARENT_DEVICE .. " in " .. soon .. " seconds")

      luup.call_timer("poll_ecobee", 1, tostring(soon), "", "")
    end
