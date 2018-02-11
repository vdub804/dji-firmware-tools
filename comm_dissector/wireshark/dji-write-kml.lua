-- dji-write-kml.lua
--------------------------------------------------------------------------------
--[[
    This is a Wireshark Lua-based KML file exporter for DJI packets.

    To enable debug output in LUA console, set `console.log.level: 252` in
    Wireshark `preferences` file.
--]]
--------------------------------------------------------------------------------

local wireshark_name = "Wireshark"
if not GUI_ENABLED then
    wireshark_name = "Tshark"
end

-- verify Wireshark is new enough
local major, minor, micro = get_version():match("(%d+)%.(%d+)%.(%d+)")
if major and tonumber(major) <= 1 and ((tonumber(minor) <= 10) or (tonumber(minor) == 11 and tonumber(micro) < 3)) then
        error(  "Sorry, but your " .. wireshark_name .. " version (" .. get_version() .. ") is too old for this script!\n" ..
                "This script needs " .. wireshark_name .. "version 1.11.3 or higher.\n" )
end

-- verify we have the FileHandler class in wireshark
assert(register_menu, wireshark_name .. " does not have the register_menu func!")

-- Default settings to be stored within private_table
local default_settings =
{
    packets = {},
    lookat = { lon = 0.0, lat = 0.0, alt = 0.0, rng = 1.0, },
    path_type = 0,
    ground_altitude = 500.0,
}

-- Enums
local TYP_NULL, TYP_AIR_POS, TYP_RC_STAT, TYP_MOTOR_STAT = 0, 1, 2, 3

----------------------------------------
-- in Lua, we have access to encapsulation types in the 'wtap_encaps' table,
-- but those numbers don't actually necessarily match the numbers in pcap files
-- for the encapsulation type. We'll use this table to map selected encaps;
-- these are taken from wiretap/pcap-common.c
local pcap2wtap = {
    [0]   = wtap_encaps.NULL,
    [1]   = wtap_encaps.ETHERNET,
    [6]   = wtap_encaps.TOKEN_RING,
    [8]   = wtap_encaps.SLIP,
    [9]   = wtap_encaps.PPP,
    [101] = wtap_encaps.RAW_IP,
    [105] = wtap_encaps.IEEE_802_11,
    [127] = wtap_encaps.IEEE_802_11_RADIOTAP,
    [140] = wtap_encaps.MTP2,
    [141] = wtap_encaps.MTP3,
    [143] = wtap_encaps.DOCSIS,
    [147] = wtap_encaps.USER0,
    [148] = wtap_encaps.USER1,
    [149] = wtap_encaps.USER2,
    [150] = wtap_encaps.USER3,
    [151] = wtap_encaps.USER4,
    [152] = wtap_encaps.USER5,
    [153] = wtap_encaps.USER6,
    [154] = wtap_encaps.USER7,
    [155] = wtap_encaps.USER8,
    [156] = wtap_encaps.USER9,
    [157] = wtap_encaps.USER10,
    [158] = wtap_encaps.USER11,
    [159] = wtap_encaps.USER12,
    [160] = wtap_encaps.USER13,
    [161] = wtap_encaps.USER14,
    [162] = wtap_encaps.USER15,
    [186] = wtap_encaps.USB,
    [187] = wtap_encaps.BLUETOOTH_H4,
    [189] = wtap_encaps.USB_LINUX,
    [195] = wtap_encaps.IEEE802_15_4,
}

-- Makes a copy of the default settings per file
local function new_settings()
    debug("creating new file_settings")
    local file_settings = {}
    for k,v in pairs(default_settings) do
        file_settings[k] = v
    end
    return file_settings
end

-- A simple function for backward mapping of the pcap2wtap array.
local function wtap2pcap(encap)
    for k,v in pairs(pcap2wtap) do
        if v == encap then
            return k
        end
    end
    return 0
end

-- Create our ExportCaptureInfo class which will behave like CaptureInfo
local ExportCaptureInfo = {}
ExportCaptureInfo.__index = ExportCaptureInfo

function ExportCaptureInfo:create()
    local acnt = {}             -- our new object
    setmetatable(acnt,ExportCaptureInfo)  -- make ExportCaptureInfo handle lookup
    -- initialize attribs
    acnt.user_app = wireshark_name
    acnt.private_table = {}
    acnt.user_options = {}
    return acnt
end

-- Shifts given WGS84+Z coordinates by (x,y,z) shift given in meters
local function geom_wgs84_coords_shift_xyz(ocoord, icoord, shift_meters_x, shift_meters_y, shift_meters_z)
    -- one degree of longitude on the Earth surface equals 111320 meters (at the equator)
    angular_lat = icoord.lat * math.pi / 180
    delta_longitude = shift_meters_x / (111320.0 * math.cos(angular_lat))
    -- one degree of latitude on the Earth surface equals 110540 meters
    delta_latitude = shift_meters_y / 110540.0
    ocoord.lon = icoord.lon + delta_longitude * 180 / math.pi
    ocoord.lat = icoord.lat + delta_latitude * 180 / math.pi
    ocoord.alt = icoord.alt + shift_meters_z
end

-- Go though packets and interpolate missing values
local function process_packets(file_settings, packets, til_end)
    debug("process_packets() called")
    local start_air_pos = -1
    min_lon = 180.0
    min_lat = 180.0
    min_alt = 999999999.0
    max_lon = -180.0
    max_lat = -180.0
    max_alt = -999999999.0
    for pos,pkt in pairs(packets) do
        if (pkt.typ == TYP_AIR_POS) then
            if (pkt.lon ~= 0.0) or (pkt.lat ~= 0.0) then
                -- Add the value to limits
                if (pkt.lon < min_lon) then
                    min_lon = pkt.lon
                end
                if (pkt.lat < min_lat) then
                    min_lat = pkt.lat
                end
                if (pkt.alt < min_alt) then
                    min_alt = pkt.alt
                end
                if (pkt.lon > max_lon) then
                    max_lon = pkt.lon
                end
                if (pkt.lat > max_lat) then
                    max_lat = pkt.lat
                end
                if (pkt.alt > max_alt) then
                    max_alt = pkt.alt
                end
                if (pos - start_air_pos > 1) then
                    -- We've reached the end of a block with unset air_pos inside
                    local spkt = {}
                    if (start_air_pos >= 0) then
                        spkt = packets[start_air_pos]
                    else
                        spkt = packets[pos]
                        start_air_pos = 0
                    end
                    for cpos = start_air_pos+1, pos-1, 1 do
                        local cpkt = packets[cpos]
                        -- TODO we should assume linear time, not linear index
                        cpkt.lon = spkt.lon + (pkt.lon - spkt.lon) * (cpos - start_air_pos) / (pos - start_air_pos)
                        cpkt.lat = spkt.lat + (pkt.lat - spkt.lat) * (cpos - start_air_pos) / (pos - start_air_pos)
                        -- mark the packet as fixed in postprocessing, not from real measurement
                        cpkt.fixd = true
                        -- mark the packet as processed
                        cpkt.proc = true
                    end
                end
                start_air_pos = pos
                -- mark the packet as processed
                pkt.proc = true
            end
        end
    end
    if (file_settings.lookat.lon == 0.0) or (file_settings.lookat.lat == 0.0) then
        if (min_lon < 0) and (max_lon > 0) then
            local max_tmp = max_lon
            max_lon = 180.0 - min_lon
            min_lon = max_tmp
        end
        if (min_lat < 0) and (max_lat > 0) then
            local max_tmp = max_lat
            max_lat = 180.0 - min_lat
            min_lat = max_tmp
        end
        file_settings.lookat.lon = min_lon + (max_lon - min_lon)/2
        file_settings.lookat.lat = min_lat + (max_lat - min_lat)/2
        file_settings.lookat.alt = min_alt + (max_alt - min_alt)/2 + file_settings.ground_altitude
        
        local R = 6378137.0 -- Radius of earth in meters
        local angular_dist = max_lon * math.pi / 180 - min_lon * math.pi / 180
        local a = math.sin(angular_dist/2) * math.sin(angular_dist/2)
        local c_lon = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        local angular_dist = max_lat * math.pi / 180 - min_lat * math.pi / 180
        local a = math.sin(angular_dist/2) * math.sin(angular_dist/2)
        local c_lat = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
        -- Compute range as max of path dimensions plus not lower than 10 m
        file_settings.lookat.rng = math.max(R * math.max(c_lon, c_lat), 10.0)
    end
end

--------------------------------------------------------------------------------
-- high-level file writer handling functions for Wireshark to use
--------------------------------------------------------------------------------

-- file encaps we can handle writing
local canwrite = {
    [ wtap_encaps.USER0 ]       = true,
    [ wtap_encaps.USER1 ]       = true,
    [ wtap_encaps.USER2 ]       = true,
    [ wtap_encaps.USER3 ]       = true,
    [ wtap_encaps.USER4 ]       = true,
    [ wtap_encaps.USER5 ]       = true,
    [ wtap_encaps.USER6 ]       = true,
    [ wtap_encaps.USER7 ]       = true,
    [ wtap_encaps.USER8 ]       = true,
    [ wtap_encaps.USER9 ]       = true,
    [ wtap_encaps.USER10 ]       = true,
    [ wtap_encaps.USER11 ]       = true,
    [ wtap_encaps.USER12 ]       = true,
    [ wtap_encaps.USER13 ]       = true,
    [ wtap_encaps.USER14 ]       = true,
    [ wtap_encaps.USER15 ]       = true,
    -- etc., etc.
}

-- we can't reuse the variables we used in the reader, because this script might be used to both
-- open a file for reading and write it out, at the same time, so we cerate another file_settings
-- instance.
local function create_writer_file_settings()
    debug("create_writer_file_settings() called")

    local file_settings = new_settings()

    return file_settings
end

----------------------------------------
-- The can_write_encap() function is called by Wireshark when it wants to write out a file,
-- and needs to see if this file writer can handle the packet types in the window.
-- We need to return true if we can handle it, else false
local function can_write_encap(encap)
    debug("can_write_encap() called with encap=" .. encap)
    return canwrite[encap] or false
end

local function write_open(fh, capture)
    debug("write_open() called")

    local file_settings = create_writer_file_settings()

    -- It would be nice to keep altitude relative to ground. Unfortunately, one
    -- of KML restrictions is that there is no way to make a path relative to
    -- one specific point on the ground. Relative path is relative in every point.
    -- Obviously this is not what we want, so the only solution is to use absolute
    -- positions. Without that, even parts of the drone model would have different
    -- positions on different coordinates.
    local tmp_val = tonumber(capture.user_options.ground_alt, 10)
    if (tmp_val ~= nil) then
        file_settings.ground_altitude = tmp_val
    end

    local tmp_val = capture.user_options.path_style
    if (tmp_val ~= nil and tmp_val ~= '') then
        file_settings.path_style = tmp_val
    end

    -- write out file header
    local hdr = [[<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
  <Document>
    <name>Dji Flight Log - FILENAME</name>
    <open>1</open>
    <description>Path configuration: TODO</description>
    <!-- For best viewing experience, select "Do not automatically tilt while zooming"
         option in Google Earth "Navigation" config tab. -->
    <Style id="purpleLineGreenPoly">
      <IconStyle>
        <Icon>
          <href>onepx_trans.png</href>
        </Icon>
        <scale>0</scale>
      </IconStyle>
      <LabelStyle>
        <scale>0</scale>
      </LabelStyle>
      <LineStyle>
        <color>7fff00ff</color>
        <width>4</width>
      </LineStyle>
      <PolyStyle>
        <color>7f00ff00</color>
      </PolyStyle>
    </Style>
    <Style id="yellowLineGreenPoly">
      <IconStyle>
        <Icon>
          <href>onepx_trans.png</href>
        </Icon>
        <scale>0</scale>
      </IconStyle>
      <LabelStyle>
        <scale>0</scale>
      </LabelStyle>
      <LineStyle>
        <color>7f00ffff</color>
        <width>4</width>
      </LineStyle>
      <PolyStyle>
        <color>7f00ff00</color>
      </PolyStyle>
    </Style>
    <Style id="noLineNoPoly">
      <IconStyle>
        <Icon>
          <href>onepx_trans.png</href>
        </Icon>
        <scale>0</scale>
      </IconStyle>
      <LabelStyle>
        <scale>0</scale>
      </LabelStyle>
      <LineStyle>
        <color>00ffffff</color>
        <width>0</width>
      </LineStyle>
      <PolyStyle>
        <color>00ffffff</color>
        <fill>0</fill>
        <outline>0</outline>
      </PolyStyle>
    </Style>
]]
    if not hdr then
        info("write_open: error generating file header")
        return false
    end

    if not fh:write(hdr) then
        info("write_open: error writing file header to file")
        return false
    end

    -- save settings
    capture.private_table = file_settings

    return true
end

-- declare some field extractors
local dji_p3_rec_etype = Field.new("dji_p3.rec_etype")
-- P3 flight record packet 0x000c
local dji_p3_rec_osd_general_longtitude = Field.new("dji_p3.rec_osd_general_longtitude")
local dji_p3_rec_osd_general_latitude = Field.new("dji_p3.rec_osd_general_latitude")
local dji_p3_rec_osd_general_relative_height = Field.new("dji_p3.rec_osd_general_relative_height")
-- P3 flight record packet 0x0000
local dji_p3_rec_controller_g_real_input_channel_command_aileron = Field.new("dji_p3.rec_controller_g_real_input_channel_command_aileron")
local dji_p3_rec_controller_g_real_input_channel_command_elevator = Field.new("dji_p3.rec_controller_g_real_input_channel_command_elevator")
local dji_p3_rec_controller_g_real_input_channel_command_throttle = Field.new("dji_p3.rec_controller_g_real_input_channel_command_throttle")
local dji_p3_rec_controller_g_real_input_channel_command_rudder = Field.new("dji_p3.rec_controller_g_real_input_channel_command_rudder")
local dji_p3_rec_controller_g_real_input_channel_command_mode = Field.new("dji_p3.rec_controller_g_real_input_channel_command_mode")
local dji_p3_rec_controller_g_real_status_control_real_mode = Field.new("dji_p3.rec_controller_g_real_status_control_real_mode")
local dji_p3_rec_controller_g_real_status_ioc_control_command_mode = Field.new("dji_p3.rec_controller_g_real_status_ioc_control_command_mode")
local dji_p3_rec_controller_g_real_status_rc_state = Field.new("dji_p3.rec_controller_g_real_status_rc_state")
local dji_p3_rec_controller_g_real_status_motor_status = Field.new("dji_p3.rec_controller_g_real_status_motor_status")
local dji_p3_rec_controller_g_real_status_main_batery_voltage = Field.new("dji_p3.rec_controller_g_real_status_main_batery_voltage")

local function write(fh, capture, pinfo)
    debug("write() called")

    -- get file settings
    local file_settings = capture.private_table
    if not file_settings then
        info("write() failed to get private table file settings")
        return false
    end

    --local tvbrange = fldinfo.range
    --fh:write( tobinary( tostring( tvbrange:bytes() ) ) )
    --fh:flush()

    -- Get fields from new packet
    local curr_pkt = {
        typ = TYP_NULL,
        proc = false,
        fixd = false,
    }

    local pkt_rec_etype = { dji_p3_rec_etype() }

    if (pkt_rec_etype[1].value == 0x000c) then
        local new_air_longtitude = { dji_p3_rec_osd_general_longtitude() }
        local new_air_latitude = { dji_p3_rec_osd_general_latitude() }
        local new_air_rel_altitude = { dji_p3_rec_osd_general_relative_height() }

        curr_pkt.lon = (new_air_longtitude[1].value * 180.0 / math.pi)
        curr_pkt.lat = (new_air_latitude[1].value * 180.0 / math.pi)
        curr_pkt.alt = new_air_rel_altitude[1].value * 0.1
        curr_pkt.typ = TYP_AIR_POS
    elseif (pkt_rec_etype[1].value == 0x0000) then
        local new_motor_status = { dji_p3_rec_controller_g_real_status_motor_status() }
        curr_pkt.motor_status = new_motor_status[1].value
        curr_pkt.typ = TYP_MOTOR_STAT
        table.insert(file_settings.packets, curr_pkt)

        --local new_batery_voltage = { dji_p3_rec_controller_g_real_status_main_batery_voltage() }

        local curr_pkt = {
            typ = TYP_NULL,
            proc = false,
            fixd = false,
        }
        local new_input_aileron = { dji_p3_rec_controller_g_real_input_channel_command_aileron() }
        local new_input_elevator = { dji_p3_rec_controller_g_real_input_channel_command_elevator() }
        local new_input_throttle = { dji_p3_rec_controller_g_real_input_channel_command_throttle() }
        local new_input_rudder = { dji_p3_rec_controller_g_real_input_channel_command_rudder() }
        local new_input_mode = { dji_p3_rec_controller_g_real_input_channel_command_mode() }
        local new_control_real_mode = { dji_p3_rec_controller_g_real_status_control_real_mode() }
        local new_ioc_control_mode = { dji_p3_rec_controller_g_real_status_ioc_control_command_mode() }
        local new_rc_state = { dji_p3_rec_controller_g_real_status_rc_state() }
        curr_pkt.aileron = new_input_aileron[1].value
        curr_pkt.elevator = new_input_elevator[1].value
        curr_pkt.throttle = new_input_throttle[1].value
        curr_pkt.rudder = new_input_rudder[1].value
        curr_pkt.input_mode = new_input_mode[1].value
        curr_pkt.real_mode = new_control_real_mode[1].value
        curr_pkt.control_mode = new_ioc_control_mode[1].value
        curr_pkt.rc_state = new_rc_state[1].value
        curr_pkt.typ = TYP_RC_STAT
    end

    if (curr_pkt.typ ~= TYP_NULL) then
        table.insert(file_settings.packets, curr_pkt)
    end

    -- It would be nice to store packets when we're starting to keep too much of them;
    -- but with all the features we have, that probably won't be possible
    --if table.getn(file_settings.packets) > 1024 then
    --    process_packets(file_settings, file_settings.packets, false)
    --    ...
    --end

    --warn("aaa" .. tostring(new_air_longtitude))
    -- first get times
    --local nstime = fldinfo.time

    -- pcap format is in usecs, but wireshark's internal is nsecs
    --local nsecs = nstime.nsecs

    return true
end

local function write_lookat(fh, indent, lookat, head, tilt, altmode)
    local blk = indent .. [[<LookAt>
]] .. indent .. [[  <longitude>]] .. lookat.lon .. [[</longitude>
]] .. indent .. [[  <latitude>]] .. lookat.lat .. [[</latitude>
]] .. indent .. [[  <altitude>]] .. lookat.alt .. [[</altitude>
]] .. indent .. [[  <heading>]] .. head .. [[</heading>
]] .. indent .. [[  <tilt>]] .. tilt .. [[</tilt>
]] .. indent .. [[  <range>]] .. lookat.rng .. [[</range>
]] .. indent .. [[  <altitudeMode>]] .. altmode .. [[</altitudeMode>
]] .. indent .. [[</LookAt>
]]
    return fh:write(blk)
end

local function write_static_paths_folder(fh, file_settings)
    debug("write_static_paths_folder() called")
    local blk = [[    <Folder>
      <name>Static paths</name>
      <visibility>1</visibility>
      <description>Flight path.</description>
      <Placemark>
        <name>Whole path</name>
        <visibility>1</visibility>
        <description>Flight path line</description>
        <styleUrl>#purpleLineGreenPoly</styleUrl>
]]

    if not fh:write(blk) then
        info("write: error writing path block head to file")
        return false
    end

    if not write_lookat(fh, "        ", file_settings.lookat, -45.0, 45.0, "relativeToGround") then
        info("write: error writing lookat block to file")
        return false
    end

    local blk = [[        <LineString>
          <extrude>0</extrude>
          <tessellate>0</tessellate>
          <!-- <altitudeMode>absolute</altitudeMode> -->
          <!-- <altitudeMode>relativeToGround</altitudeMode> -->
          <altitudeMode>clampToGround</altitudeMode>
          <coordinates>
]]
    if not fh:write(blk) then
        info("write: error writing path block head to file")
        return false
    end

    for pos,pkt in pairs(file_settings.packets) do
        if (pkt.typ == TYP_AIR_POS) then
            local pathblk_line = "            " .. pkt.lon .. "," .. pkt.lat .. "," .. pkt.alt .. "\n"
            if not fh:write(pathblk_line) then
                info("write: error writing path block line to file")
                return false
            end
        end
    end

    local blk = [[          </coordinates>
        </LineString>
      </Placemark>
    </Folder>
]]
    if not fh:write(blk) then
        info("write: error writing path block tail to file")
        return false
    end
end

local function write_dynamic_paths_placemark(fh, file_settings, model_info)
    debug("write_dynamic_paths_placemark() called")

    local blk = [[      <Placemark>
        <name>Aircraft ]] .. model_info.part_name .. [[ path</name>
        <visibility>1</visibility>
        <styleUrl>#]] .. model_info.line_style .. [[</styleUrl>
        <gx:Track>
          <extrude>0</extrude>
          <altitudeMode>absolute</altitudeMode>
          <!-- <altitudeMode>relativeToGround</altitudeMode> -->
          <Model id="aircraft]] .. model_info.part_name .. [[">
            <Orientation>
              <heading>]] .. model_info.head .. [[</heading>
              <tilt>]] .. model_info.tilt .. [[</tilt>
              <roll>]] .. model_info.roll .. [[</roll>
            </Orientation>
            <Scale>
              <x>]] .. model_info.scale .. [[</x>
              <y>]] .. model_info.scale .. [[</y>
              <z>]] .. model_info.scale .. [[</z>
            </Scale>
            <Link>
              <href>]] .. model_info.fname .. [[</href>
              <refreshMode>once</refreshMode>
            </Link>
          </Model>
]]
    if not fh:write(blk) then
        info("write: error writing path block head to file")
        return false
    end

    for pos,pkt in pairs(file_settings.packets) do
        if (pkt.typ == TYP_AIR_POS) then
            -- TODO use proper timestamp when available
            local ts = os.time{year=2018, month=1, day=1, hour=0} + pos / 100
            -- First entry must be at a whole second, or stranger things will happen
            if (pos == 1) then
                ts = math.floor(ts)
            end
            local pathblk_line = "          <when>" .. os.date('%Y-%m-%dT%H:%M:%S', ts) .. string.format(".%03dZ", (ts * 1000) % 1000) .. "</when>\n"
            if not fh:write(pathblk_line) then
                info("write: error writing path block line to file")
                return false
            end
        end
    end

    for pos,pkt in pairs(file_settings.packets) do
        if (pkt.typ == TYP_AIR_POS) then
            local coord = {}
            geom_wgs84_coords_shift_xyz(coord, pkt, model_info.shift_x, model_info.shift_y, file_settings.ground_altitude + model_info.shift_z)
            local pathblk_line = "          <gx:coord>" .. coord.lon .. " " .. coord.lat .. " " .. coord.alt .. "</gx:coord>\n"
            if not fh:write(pathblk_line) then
                info("write: error writing path block line to file")
                return false
            end
        end
    end

    for pos,pkt in pairs(file_settings.packets) do
        if (pkt.typ == TYP_AIR_POS) then
            local pathblk_line = "          <gx:angles>" .. 0.0 .. " " .. 0.0 .. " " .. 0.0 .. "</gx:angles>\n"
            if not fh:write(pathblk_line) then
                info("write: error writing path block line to file")
                return false
            end
        end
    end

    local blk = [[        </gx:Track>
      </Placemark>
]]
    if not fh:write(blk) then
        info("write: error writing path block tail to file")
        return false
    end
end

local function write_dynamic_paths_folder(fh, file_settings)
    debug("write_dynamic_paths_folder() called")
    local blk = [[    <Folder>
      <name>Dynamic paths</name>
      <visibility>1</visibility>
      <description>Flight path over time.</description>
]]
    if not fh:write(blk) then
        info("write: error writing path block head to file")
        return false
    end

    local model_info = { head=0.0, tilt=-90.0, roll=0.0, scale=0.005, line_style = "yellowLineGreenPoly",
        part_name="Body", fname="phantom_3_body_dec2.dae", shift_x=0.0, shift_y=0.0, shift_z=0.1 }
    write_dynamic_paths_placemark(fh, file_settings, model_info)

    local model_info = { head=0.0, tilt=-90.0, roll=0.0, scale=0.005, line_style = "noLineNoPoly",
        part_name="Prop1", fname="phantom_3_prop_singl_run2.dae", shift_x=0.0109, shift_y=0.0109, shift_z=0.15 }
    write_dynamic_paths_placemark(fh, file_settings, model_info)

    local model_info = { head=0.0, tilt=-90.0, roll=0.0, scale=0.005, line_style = "noLineNoPoly",
        part_name="Prop2", fname="phantom_3_prop_singl_run2.dae", shift_x=0.0109, shift_y=-0.0109, shift_z=0.15 }
    write_dynamic_paths_placemark(fh, file_settings, model_info)

    local model_info = { head=0.0, tilt=-90.0, roll=0.0, scale=0.005, line_style = "noLineNoPoly",
        part_name="Prop3", fname="phantom_3_prop_singl_run2.dae", shift_x=-0.0109, shift_y=-0.0109, shift_z=0.15 }
    write_dynamic_paths_placemark(fh, file_settings, model_info)

    local model_info = { head=0.0, tilt=-90.0, roll=0.0, scale=0.005, line_style = "noLineNoPoly",
        part_name="Prop4", fname="phantom_3_prop_singl_run2.dae", shift_x=-0.0109, shift_y=0.0109, shift_z=0.15 }
    write_dynamic_paths_placemark(fh, file_settings, model_info)

    local blk = [[    </Folder>
]]
    if not fh:write(blk) then
        info("write: error writing path block tail to file")
        return false
    end
end

local function write_close(fh, capture)
    debug("write_close() called")

    -- get file settings
    local file_settings = capture.private_table
    if not file_settings then
        info("write() failed to get private table file settings")
        return false
    end

    process_packets(file_settings, file_settings.packets, true)

    -- Write global LookAt block
    if not write_lookat(fh, "    ", file_settings.lookat, -45.0, 45.0, "absolute") then
        info("write: error writing lookat block to file")
        return false
    end

    -- Write static paths (without time dependencies)
    write_static_paths_folder(fh, file_settings)

    -- Write the more interesting, dynamic paths
    write_dynamic_paths_folder(fh, file_settings)

    local footer = [[  </Document>
</kml>
]]
    if not fh:write(footer) then
        info("write: error writing file footer")
        return false
    end

    debug("Good night, and good luck")
    return true
end

-- do a payload dump when prompted by the user
local function init_payload_dump(filename, ground_alt_val, path_style_val)

    local packet_count = 0
    -- Osd General
    local filter = "dji_p3.rec_etype == 0x000c or dji_p3.rec_etype == 0x0000"
    local tap = Listener.new(nil,filter)
    local fh = assert(io.open(filename, "w+"))

    capture = ExportCaptureInfo:create()
    capture.user_options = { ground_alt=ground_alt_val, path_style=path_style_val }
    write_open(fh, capture)
    
    -- this function is going to be called once each time our filter matches
    function tap.packet(pinfo,tvb)

        if ( true ) then
            packet_count = packet_count + 1

            -- there can be multiple packets in a given frame, so get them all into a table
            --local contents = { dji_p3_pkt() }

            --for i,fldinfo in ipairs(contents) do
                write(fh, capture, pinfo)
            --end
        end
    end
    
    -- re-inspect all the packets that are in the current capture, thereby
    -- triggering the above tap.packet function
    retap_packets()

    -- prepare for cleanup
    write_close(fh, capture)
    -- cleanup
    fh:close()
    tap:remove()
    info("Dumped packets: " .. packet_count )
end

-- show this dialog when the user select "Export" from the Tools menu
local function begin_dialog_menu()    
    new_dialog("KML path of DJI drone flight writer", init_payload_dump,
      "Output file\n(type KML file name)",
      "Ground level altitude\n(altitude at the starting point, in meters; default="..default_settings.ground_altitude..")",
      "Path style\n(flat, line, wall) UNUSED")
end

register_menu("Export KML from DJI drone flight", begin_dialog_menu, MENU_TOOLS_UNSORTED)

debug("Tools Menu Handler registered")
