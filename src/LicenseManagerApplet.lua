
--[[
=head1 NAME

applets.LicenseManager.LicenseManagerApplet - License manager which validate applet licenses

=head1 DESCRIPTION

This is a license manager implementation which validates applet licenses

=head1 FUNCTIONS

Applet related methods are described in L<jive.Applet>. 

=cut
--]]


-- stuff we use
local pairs, ipairs, tostring, tonumber, setmetatable, package, type = pairs, ipairs, tostring, tonumber, setmetatable, package, type

local oo	       = require("loop.simple")
local os	       = require("os")
local io	       = require("io")
local math	     = require("math")
local string	   = require("jive.utils.string")
local sha1	     = require("sha1")

local Applet	   = require("jive.Applet")
local Window	   = require("jive.ui.Window")
local Group	    = require("jive.ui.Group")
local Label	    = require("jive.ui.Label")
local Textarea	    = require("jive.ui.Textarea")
local SimpleMenu       = require("jive.ui.SimpleMenu")
local Checkbox	 = require("jive.ui.Checkbox")
local Font	     = require("jive.ui.Font")
local Framework	= require("jive.ui.Framework")
local Timer	    = require("jive.ui.Timer")
local SocketHttp       = require("jive.net.SocketHttp")
local RequestHttp      = require("jive.net.RequestHttp")

local System	   = require("jive.System")
local DateTime	 = require("jive.utils.datetime")

local appletManager    = appletManager
local jiveMain	 = jiveMain
local jnt	      = jnt

local debug		   = require("jive.utils.debug")
local Viewer = require("loop.debug.Viewer")

local WH_FILL	   = jive.ui.WH_FILL
local LAYOUT_NONE       = jive.ui.LAYOUT_NONE

module(..., Framework.constants)
oo.class(_M, Applet)


local version = "1.0"
local backlog = {}

----------------------------------------------------------------------------------------
-- Helper Functions
--

function init(self)
	jnt:subscribe(self)
end

function notify_licenseChanged(self,appletId)
	log:debug("Changed license for "..appletId)
	if self.window then
		self.window:hide()
		self:licenseManagerMenu()
	end
end

function licenseManagerMenu(self,transiton)
	self.window = Window("text_list",self:string("APPLET_LICENSEMANAGER"), 'settingstitle')
	local menu = SimpleMenu("menu")

	local licensedApplets = self:getSettings()["licenses"]

	local accountId = self:getSettings()["accountId"]
	if not accountId then
		for _,server in appletManager:callService("iterateSqueezeCenters") do
			self:notify_serverConnected(server)
		end
	end
	if accountId then
		menu:setHeaderWidget(Textarea("help_text", tostring(self:string("APPLET_LICENSEMANAGER_ACCOUNT_ID")).."\n"..accountId.."\n"..tostring(self:string("APPLET_LICENSEMANAGER_LICENSE_REFRESH"))))
	else
		menu:setHeaderWidget(Textarea("help_text", tostring(self:string("APPLET_LICENSEMANAGER_UNKNOWN_ACCOUNT_ID"))))
	end
	for id,item in pairs(licensedApplets) do		
		if self:isLicensedApplet(item.name) then
			menu:addItem(
				{
					style = 'item_no_icon',
					text = item.name.." ("..tostring(self:string("APPLET_LICENSEMANAGER_LICENSED"))..")"
				}
			)
		else
			menu:addItem(
				{
					text = item.name.." ("..tostring(self:string("APPLET_LICENSEMANAGER_LICENSE_REQUIRED"))..")",
					callback = function(object, menuItem)
						self.appletwindow = self:showAppletDetails(item.name, item.licenseHelp)
						return EVENT_CONSUME
				        end,

				}
			)
		end
	end

	menu:addItem(
		{
			text = self:string("APPLET_LICENSEMANAGER_REFRESH_LICENSES"),
			callback = function(object, menuItem)
				local accountId = self:getSettings()["accountId"]
				if not accountId then
					for _,server in appletManager:callService("iterateSqueezeCenters") do
						self:notify_serverConnected(server)
					end
				end
				if accountId then
					local licensedApplets = self:getSettings()["licenses"]
					for appletId,data in pairs(licensedApplets) do
						licensedApplets[appletId].date = nil
						licensedApplets[appletId].nextcheck = nil
					end
					self:storeSettings()
					for appletId in ipairs(licensedApplets) do
						self:isLicensedApplet(appletId,licensedApplets[appletId].version)
					end
				end
				self.window:hide()
				self:licenseManagerMenu()
				return EVENT_CONSUME
			end,
		}
	)

	self.window:addWidget(menu)
	self:tieAndShowWindow(self.window)
end

function showAppletDetails(self,appletId,licenseHelp)
	local window = Window("text_list",appletId)
	local menu = SimpleMenu("menu")
	window:addWidget(menu)

	local description = tostring(self:string("APPLET_LICENSEMANAGER_LICENSE_REQUIRED")).."\n\n"
	if licenseHelp then
		description = description .. licenseHelp .."\n"
	else
		description = description .. tostring(self:string("APPLET_LICENSEMANAGER_CONTACT_DEVELOPER"))
	end
	menu:setHeaderWidget(Textarea("help_text",description))

	self:tieAndShowWindow(window)
	return window
end

function registerLicensedApplet(self,appletId,appletVersion,licenseHelp)
	local licensedApplets = self:getSettings()["licenses"]

	if not licensedApplets[appletId] then
		if appletVersion then
			backlog[appletId] = appletVersion
		else
			backlog[appletId] = 0
		end
		licensedApplets[appletId] = {
			name = appletId,
			licenseHelp = licenseHelp,
		}
	else
		licensedApplets[appletId].licenseHelp = licenseHelp
	end
end

function isLicensedApplet(self,appletId,appletVersion)
	local licensedApplets = self:getSettings()["licenses"]
	local accountId = self:getSettings()["accountId"]

	log:debug("Checking license for "..appletId)
	if not accountId then
		if appletVersion then
			backlog[appletId] = appletVersion
		else
			backlog[appletId] = 0
		end
		return false
	end

	if self:validateLicense(appletId,appletVersion) then
		return true
	end

	self:retrieveLicense(appletId,appletVersion)
	return false
end

function validateLicense(self,appletId,appletVersion)
	local licensedApplets = self:getSettings()["licenses"]
	local accountId = self:getSettings()["accountId"]

	if licensedApplets[appletId] then
		if licensedApplets[appletId].date then
			log:debug("Validating towards date: "..licensedApplets[appletId].date)
			if not appletVersion then
				appletVersion = ''
			end
			local sha1 = sha1:new()
			sha1:update(version..":"..appletId..":"..appletVersion..":"..licensedApplets[appletId].date..":"..accountId)
			local result = sha1:digest()
			if result == licensedApplets[appletId].checksum then
				local current = os.time()
				local date = dateFromString(licensedApplets[appletId].date)
				if current<date then
					return true
				end
			end
		end
	end
	return false
end

function dateFromString(dateString)
	if string.len(dateString) != 10 then
		return 0
	end
	local year = string.sub(dateString,1,4)
	local month = string.sub(dateString,6,7)
	local day = string.sub(dateString,9,10)
	return os.time({year=year,month=month,day=day})
end

function retrieveLicense(self,appletId,appletVersion)
	local licensedApplets = self:getSettings()["licenses"]
	local accountId = self:getSettings()["accountId"]
	
	local current = os.time()
	if not licensedApplets[appletId] or not licensedApplets[appletId].nextcheck or current>licensedApplets[appletId].nextcheck then
		local versionString = ""
		if appletVersion then
			versionString = "&version="..appletVersion
		else
			appletVersion = ""
		end
		log:debug("Requesting license for "..appletId.." "..appletVersion)
		local http = SocketHttp(jnt, "license.isaksson.info", 80)
		local req = RequestHttp(function(chunk, err)
				if err then
					log:warn(err)
				elseif chunk then
					local date = string.gsub(chunk,"\n","")
					log:debug("Adding license entry for: "..appletId.." "..appletVersion)
					local sha1 = sha1:new()
					sha1:update(version..":"..appletId..":"..appletVersion..":"..date..":"..accountId)
					local result = sha1:digest()

					if date == "" then
						date = nil
					end

					local licenseHelp = nil

					if licensedApplets[appletId] then
						licenseHelp = licensedApplets[appletId].licenseHelp
					end

					licensedApplets[appletId] = {
						name = appletId,
						version = appletVersion,
						date = date,
						checksum = result,
						licenseHelp = licenseHelp
					}

					if self:validateLicense(appletId,appletVersion) then
						self:storeSettings()
						jnt:notify("licenseChanged",appletId)
					else
						local current = os.time()
						licensedApplets[appletId].nextcheck = current + (3600*24)
						self:storeSettings()
					end
				end
			end,
			'GET', "/getlicense.php?user="..accountId.."&application="..appletId..versionString)
		http:fetch(req)
	end
end

function notify_currentPlayer(self,player)
	local accountId = self:getSettings()["accountId"]
	if not self.accountId then
		local server = player:getSlimServer()
		if server and server:isConnected() then
			if server:isSqueezeNetwork() then
				self:loadAccountIdFromSqueezeNetwork(server,player)
			else
				self:loadAccountIdFromSqueezeboxServer(server,player)
			end
		end
	end
end

function notify_serverConnected(self,server)
	local accountId = self:getSettings()["accountId"]
	if not accountId then
		local player = appletManager:callService("getCurrentPlayer")
		if server:isSqueezeNetwork() then
			self:loadAccountIdFromSqueezeNetwork(server,player)
		else
			self:loadAccountIdFromSqueezeboxServer(server,player)
		end
	end
end

function validateBacklog(self) 
	for appletId,appletVersion in pairs(backlog) do
		if appletVersion != 0 then
			log:debug("Getting backlog license for "..appletId.."="..appletVersion)
			self:isLicensedApplet(appletId,appletVersion)
		else
			log:debug("Getting backlog license for "..appletId)
			self:isLicensedApplet(appletId)
		end
		backlog[appletId] = nil
	end
end

function loadAccountIdFromSqueezeNetwork(self,server,player)
	if player then
		log:debug("Getting account id from: ".. server['name'])
		server:userRequest(function(chunk,err)
				if err then
					log:warn("Couldn't get account id from: "..server['name'].." using primary method")
					log:warn(err)
				else
					if chunk.data.window then
						local accountId = chunk.data.window.textarea
						accountId = string.sub(accountId,string.find(accountId,"%S+@%S+",1))
						accountId = string.gsub(accountId,"[%.,]$","")
						log:info("Got accountId="..accountId.." from "..server['name'])
						self:getSettings()["accountId"] = self:createAccountId(accountId)
						self:storeSettings()
						self:validateBacklog()
					else
						log:debug("Couldn't get account id from: "..server['name'].." using primary method")
						server:userRequest(function(chunk,err)
								if err then
									log:warn(err)
								else
									log:debug("Parsing result from first level systeminfo command")
									debug.dump(chunk.data)
									if chunk.data.loop_loop and chunk.data.loop_loop[1] and chunk.data.loop_loop[1].id then
										server:userRequest(function(chunk,err)
												if err then
													log:warn("Couldn't get account id from: "..server['name'].." using secondary method")
													log:warn(err)
												else
													log:debug("Parsing result from second level systeminfo command")
													for id,item in pairs(chunk.data.loop_loop) do
														if item.name and string.find(item.name,"@",1) then
															if not self:getSettings()["accountId"] then
																local accountId = string.sub(item.name,string.find(item.name,"%S+@%S+",1))
																accountId = string.gsub(accountId,"[%.,]$","")
																log:info("Got accountId="..accountId.." from "..server['name'])
																self:getSettings()["accountId"] = self:createAccountId(accountId)
																self:storeSettings()
																self:validateBacklog()
															end
														end
													end
													if not self:getSettings()["accountId"] then
														log:warn("Couldn't get account id from: "..server['name'].." using secondary method")
													end
												end
											end,
											player:getId(),
											{'systeminfo','items',0,200,'item_id:'..chunk.data.loop_loop[1].id}
										)
									else
										log:warn("Couldn't get account id from: "..server['name'].." using secondary method")
									end
								end
							end,
							player:getId(),
							{'systeminfo','items',0,1}
						)
					end
				end
			end,
			player:getId(),
			{'register','0','100','service:SN'}
		)
	end
end
	
function loadAccountIdFromSqueezeboxServer(self,server,player)
	log:debug("Getting account id from: ".. server['name'])
	server:userRequest(function(chunk,err)
		if err then
			log:warn(err)
		elseif not string.find(tostring(chunk.data._p2),"^userdata",1) then
			local accountId=tostring(chunk.data._p2)
			log:info("Got accountId="..accountId.." from "..server['name'])
			self:getSettings()["accountId"] = self:createAccountId(accountId)
			self:storeSettings()
			self:validateBacklog()
		end
		end,
		nil,
		{'pref','sn_email','?'}
	)
end

function createAccountId(self,accountId)
	log:debug("Creating accountId for \""..accountId.."\"")
	accountId = string.gsub(accountId,"\n","")
	local sha1 = sha1:new()
	sha1:update(accountId)
	local result = sha1:digest()
	return result
end

--[[

=head1 LICENSE

Copyright 2011, Erland Isaksson (erland_i@hotmail.com)
Copyright 2010, Logitech, inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Logitech nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL LOGITECH, INC BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
--]]

